#!/usr/bin/env perl
# Name:           snpfile_annotate_mongo_redis_queue.pl
# Description:
# Date Created:   Wed Dec 24
# By:             Alex Kotlar
# Requires: Snpfile::AnnotatorBase

#Todo: Handle job expiration (what happens when job:id expired; make sure no other job operations happen, let Node know via sess:?)
#There may be much more performant ways of handling this without loss of reliability; loook at just storing entire message in perl, and relying on decode_json
#Todo: (Probably in Node.js): add failed jobs, and those stuck in processingJobs list for too long, back into job queue, for N attempts (stored in jobs:jobID)
use 5.16.1;
use autodie;
use Cpanel::JSON::XS;

use strict;
use warnings;

use Try::Tiny;

use lib './lib';

use forks;
use forks::shared;

use Log::Any::Adapter;
use File::Basename;
use DDP;
use Interface;

use Thread::Queue;
use IO::Socket;
#use Sys::Info;
#use Sys::Info::Constants qw( :device_cpu )
#for choosing max connections based on available resources

use Redis;

my $DEBUG = 0;
my $redisHost : shared = $ARGV[0] || 'genome.local';
my $redisPort : shared = $ARGV[1] || '6379';

#these queues are only consumed by this service
my $submittedJobsDocument : shared = 'submittedJob';
my $jobQueueName : shared          = 'submittedJobQueue';
my $jobPreStartQueue : shared      = 'submittedJobProcessingQueue';
# these queues are consumed by the calling program
# so items from these queues should not be removed by this program
# should any job fail, it will be restarted by the caller
# this queue is meant to simply to place the job in the appropriate queue
# and take the action relevant to that queue (such as start a job, or complete it)
my $jobStartedQueue : shared  = 'startedJobQueue';
my $jobFinishedQueue : shared = 'finishedJobQueue';
my $jobFailedQueue : shared   = 'failedJobQueue';

# notify the client
my $annotationMessageChannel : shared = 'annotationProgress';

# these keys should match the corresponding fields in the web server
# mongoose schema; TODO: at startup request file from webserver with this config
my $jobKeys : shared = shared_clone( {} );
$jobKeys->{inputFilePath}    = 'inputFilePath',
  $jobKeys->{attempts}       = 'attempts',
  $jobKeys->{outputFilePath} = 'outputFilePath',
  $jobKeys->{options}        = 'options',
  $jobKeys->{started}        = 'started',
  $jobKeys->{completed}      = 'completed',
  $jobKeys->{failed}         = 'failed',
  $jobKeys->{result}         = 'annotationSummary',
  $jobKeys->{assembly}       = 'assembly',
  $jobKeys->{comm}           = 'comm',
  $jobKeys->{clientComm}     = 'client',
  $jobKeys->{serverComm}     = 'server',
  $jobKeys->{log} = 'log';
  $jobKeys->{logException} = 'exceptions';

  my $configPathBaseDir : shared = "config/web/";
my $configFilePathHref : shared = shared_clone( {} );
my $semSTDOUT : shared;

sub tprint  { lock $semSTDOUT; print @_; }
sub treturn { lock $semSTDOUT; return @_; }

$|++;

my %cache;
my $Qwork : shared = new Thread::Queue;
my $Qdone : shared = new Thread::Queue;
my $done : shared  = 0;

#my $info = Sys::Info->new;
my $cpu = 4; #$info->device( CPU => my %options );

my $verbose : shared = 1;

#note that it is possible that we will have, in odd cases, a potential
#multiple number of identical items in the start, fail, and completed queues
#it is up to the job owner to figure out what to do with that
#we don't want to set up a race condition here

# TODO: we need to retry jobs that fail because of watch/race
sub handleJobStart {
  my ( $jobID, $documentKey, $submittedJob, $redis ) = @_;
  say "Handle job start submittedJob:";

  try {
    $submittedJob->{ $jobKeys->{started} } = 1;
    my $jobJSON = encode_json($submittedJob);
    #  $redis->watch($documentKey);
    $redis->multi;
    $redis->set( $documentKey, $jobJSON );
    $redis->lrem( $jobPreStartQueue, 0, $jobID );
    $redis->lpush( $jobStartedQueue, $jobID );
    my @replies = $redis->exec();
  }
  catch {
    say "Error saving Redis record in handleJobStart: $_";
    $submittedJob->{ $jobKeys->{started} } = 0;
    handleJobFailure( $jobID, $documentKey,
      'Error saving newly started job to Redis', $submittedJob, $redis );
  }
}

#handle success and failure
#expects $redis from local scope (not passed)
#look into multi-exec consequences, performance, investigate storing in redis Sets instead of linked-lists
sub handleJobSuccess {
  my ( $jobID, $documentKey, $submittedJob, $redis ) = @_;

  print "job succeeded $jobID";
  try {
    $submittedJob->{ $jobKeys->{completed} } = 1;
    my $jobJSON = encode_json($submittedJob);
    # $redis->watch($documentKey);
    $redis->multi;
    $redis->set( $documentKey, $jobJSON );
    $redis->lpush( $jobFinishedQueue, $jobID );
    my @replies = $redis->exec();
    $Qdone->enqueue($jobID);
  }
  catch {
    print "Error in handleJobSuccess: $_";
    $submittedJob->{ $jobKeys->{completed} } = 0;
    handleJobFailure( $jobID, $documentKey,
      'Error saving successful job to Redis', $submittedJob, $redis );
  }
}

sub handleJobFailure {
  my ( $jobID, $documentKey, $reason, $submittedJob, $redis ) = @_;
  
  say "job failed $jobID because of $reason";

  try {
    $submittedJob->{ $jobKeys->{failed} } = 1;
    if(ref $submittedJob->{$jobKeys->{log} }{$jobKeys->{logException} } ne "ARRAY") {
      $submittedJob->{$jobKeys->{log} }{$jobKeys->{logException} } = [$reason];
    } else {
      push(@{$submittedJob->{$jobKeys->{log} }{$jobKeys->{logException} } }, $reason);
    }
    
    my $jobJSON = encode_json($submittedJob);
    #$redis->watch($documentKey);
    $redis->multi;
    $redis->set( $documentKey, $jobJSON );
    $redis->lpush( $jobFailedQueue, $jobID );
    my @replies = $redis->exec();
    # $redis->unwatch;
  }
  catch {
    print $_;
  }
  $Qdone->enqueue($jobID);
}

sub handleJob {
  my $jobID = shift;

  say "Job id is $jobID";
  my $redis = Redis->new(
    server    => "$redisHost:$redisPort",
    reconnect => 72,
    every     => 5_000_000
  );
  my $documentKey = $submittedJobsDocument . ':' . $jobID;

  my $log_name = join '.', 'annotation', 'jobID', $jobID, 'log';
  my $log_file = File::Spec->rel2abs( ".", $log_name );
  say "writing log file here: $log_file" if $verbose;
  Log::Any::Adapter->set( 'File', $log_file );
  my $log = Log::Any->get_logger();

  my $submittedJob;

  my $inputHref;

  my $failed = 0;
  try {
    $submittedJob = decode_json( $redis->get($documentKey) );
  }
  catch {
    $log->error($_);
    $failed = 1;
    $Qdone->enqueue($jobID);
  };

  try {
    $inputHref = coerceInputs($submittedJob);

    handleJobStart( $jobID, $documentKey, $submittedJob, $redis );

    if ($verbose) {
      say "The user job data sent to annotator is: ";
      p $inputHref;
    }
    # create the annotator
    my $annotate_instance = Interface->new($inputHref);
    my $result            = $annotate_instance->annotate_snpfile;

    die 'Error: Nothing returned from annotate_snpfile' unless defined $result;

    $submittedJob->{ $jobKeys->{result} } = $result;

    $annotate_instance->compress_output;
  }
  catch {
    say $_;

    $log->error($_);
    #because here we don't have automatic logging guaranteed

    ##we now record this to exceptions instead of messages
    # if ( defined $inputHref
    #   && exists $inputHref->{messanger}
    #   && keys %{ $inputHref->{messanger} } )
    # {
    #   say "publishing message $_";
    #   $inputHref->{messanger}{message}{data} = "$_";
    #   $redis->publish( $inputHref->{messanger}{event},
    #     encode_json( $inputHref->{messanger} ) );
    # }

    $failed = 1;

    handleJobFailure( $jobID, $documentKey, $_, $submittedJob, $redis );
  };
  handleJobSuccess( $jobID, $documentKey, $submittedJob, $redis ) unless $failed;
}

#Here we may wish to read a json or yaml file containing argument mappings
sub coerceInputs {
  my $jobDetailsHref = shift;

  my $inputFilePath  = $jobDetailsHref->{ $jobKeys->{inputFilePath} };
  my $outputFilePath = $jobDetailsHref->{ $jobKeys->{outputFilePath} };
  my $debug          = $DEBUG;                                        #not, not!

  my $configFilePath = getConfigFilePath( $jobDetailsHref->{ $jobKeys->{assembly} } );

  # expects
  # @prop {String} channelKey
  # @prop {String} channelID
  # @prop {Object} message : with @prop data for the message
  my $messangerHref =
    $jobDetailsHref->{ $jobKeys->{comm} }->{ $jobKeys->{clientComm} };

  return {
    snpfile            => $inputFilePath,
    out_file           => $outputFilePath,
    config_file        => $configFilePath,
    ignore_unknown_chr => 1,
    overwrite          => 1,
    debug              => $debug,
    messanger          => $messangerHref,
    publisherAddress   => [ $redisHost, $redisPort ],
  };
}

sub getConfigFilePath {
  my $assembly = shift;

  if ( exists $configFilePathHref->{$assembly} ) {
    return $configFilePathHref->{$assembly};
  }
  else {
    my @maybePath = glob( $configPathBaseDir . $assembly . ".y*ml" );
    if ( scalar @maybePath ) {
      if ( scalar @maybePath > 1 ) {
        #should log
        say "\n\nMore than 1 config path found, choosing first";
      }

      return $maybePath[0];
    }

    die "\n\nNo config path found for the assembly $assembly. Exiting\n\n"
      ; #throws the error
    #should log here
  }
}

# how many threads we allow in the pool
# what does //= do here?
#!($cpu->count % 2) ? $cpu->count / 2 : !($cpu->count % 3) ? $cpu->count / 3 : $cpu->count || 1;
# our $W //=
#     !( $cpu->count % 2 ) ? $cpu->count / 2
#   : !( $cpu->count % 3 ) ? $cpu->count / 3
#   :                        $cpu->count || 1;

our $W = 8;

my @workers = map threads->create( \&worker, \%cache ), 1 .. $W;

sub worker {
  my $tid = threads->tid;
  #dequeue takes the socket connection from the head of the $Qwork array
  #expects from global scope $redis (redis client)
  while ( my $jobID = $Qwork->dequeue ) #do something on $data
  {
    handleJob($jobID);

    $Qdone->enqueue($jobID);
  }
}

my @listenerThreads;

#reconnect every 5 seconds, for an hour
my $normalQueue = threads->new(
  sub {
    my $redis = Redis->new(
      server    => "$redisHost:$redisPort",
      reconnect => 72,
      every     => 5_000_000
    );

    while (1) {
      #this can result in N identical items in $jobStartedQueue;
      #resolved on successful start of job on lines 89,116
      my $jobID : shared = $redis->brpoplpush( $jobQueueName, $jobPreStartQueue, 0 );

      if ($jobID) {
        print "\n\nGOT $jobID";

        $cache{$jobID} = $jobID;

        $Qwork->enqueue($jobID);
      }
      delete $cache{ $Qdone->dequeue } while $Qdone->pending;
    }
  }
);

push @listenerThreads, $normalQueue;

$_->join for @workers;

$_->join for @listenerThreads;

#If user presses control+C exit
$SIG{INT} = sub {
  #close the listener
  $done = 1;

  #set all
  $Qwork->enqueue( (undef) x $W );

  $_->kill('KILL')->kill() for @listenerThreads; #not working
};

tprint "Listener closed";

tprint "Workers done";

__END__
=head1 NAME

socket_snpfile_annotate_mongo.pl

=head1 SYNOPSIS

Add synopsis

=head1 DESCRIPTION

This programs runs a persistent socket server, listens for entries, runs requested annotation

etc
=cut

###previous work
###Todo consider performance implications, benefits of storing just key in list, using hmget to modify the job itself.
  ## Noted danger: if decode_json doesn't work properly, mangled messgae; this is an advantage of using hmget & hmset


# say "Error in decoding returned JSON $_";
# $inputHref->{messangerHref}->{message}->{data}
#   = 'Error in decoding returned JSON $_';

# $redis->publish(
#   $inputHref->{messangerHref}->{channel},
#   encode_json({$inputHref->{messangerHref} } ),
# );
# $inputHref->{messangerHref}->{message}->{data} = "Error: $_";
#     $redis->publish(
#       $inputHref->{messangerHref}->{channel},
#       encode_json({$inputHref->{messangerHref} } ),
#     );
# TODO: moved the pubsub to the web server, since it should persist
    # the "started" waypoint
    # $inputHref->{messangerHref}->{message}->{data} = "Starting job";
    # $redis->publish(
    #   $inputHref->{messangerHref}->{channel},
    #   encode_json({$inputHref->{messangerHref} } ),
    # );

  # TODO: at some point re-investigate allowing tiered failure
    # if ( $jobAttempts > $maxAttempts ) {
    #   $redis->lpush( $jobsFinalFailedListName, $jobID );
    # }
    # else {
    #   $redis->lpush( $jobFailedQueue, $jobID );
    # }

    #$redis->lrem( $jobStartedQueue, 0, $jobID );

#my $failedQueue = threads->new(
#   sub {
#     my $redis = Redis->new( host => $redisHost, port => $redisPort );

#     while (1) {
#       my $jobTokenJSON : shared = 
#       $redis->brpoplpush( $jobFailedQueue, $jobStartedQueue, 0 ); #this can result in N identical items in $jobStartedQueue; resolved on completion of job on lines 89,116

#       if ($jobTokenJSON) {
#         print "\n\nGOT $jobID on line 276";

#         $cache{$jobTokenJSON} = $jobTokenJSON;

#         $Qwork->enqueue($jobTokenJSON);
#       }

#       delete $cache{ $Qdone->dequeue } while $Qdone->pending;
#     }
#   }
# );

# push @listenerThreads, $failedQueue;
