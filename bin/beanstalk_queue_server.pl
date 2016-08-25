#!/usr/bin/env perl
# Name:           snpfile_annotate_mongo_redis_queue.pl
# Description:
# Date Created:   Wed Dec 24
# By:             Alex Kotlar
# Requires: Snpfile::AnnotatorBase

#Todo: Handle job expiration (what happens when job:id expired; make sure no other job operations happen, let Node know via sess:?)
#There may be much more performant ways of handling this without loss of reliability; loook at just storing entire message in perl, and relying on decode_json
#Todo: (Probably in Node.js): add failed jobs, and those stuck in processingJobs list for too long, back into job queue, for N attempts (stored in jobs:jobID)
use 5.10.0;
use Cpanel::JSON::XS;

use strict;
use warnings;

use Try::Tiny;

use lib './lib';

use Log::Any::Adapter;
use File::Basename;
use DDP;
use Interface;

use Beanstalk::Client;
use 5.10.0;
use strict;
use warnings;
use DDP;

use YAML::XS qw/LoadFile/;
# use AnyEvent;
# use AnyEvent::PocketIO::Client;
#use Sys::Info;
#use Sys::Info::Constants qw( :device_cpu )
#for choosing max connections based on available resources

# max of 1 job at a time for now
my $pm = Parallel::ForkManager->new(1);

my $DEBUG = 0;
my $conf = LoadFile('./config/queue.yaml');

# Beanstalk servers will be sharded
my $beanstalkHost  = $conf->{beanstalk_host_1};
my $beanstalkPort  = $conf->{beanstalk_port_1};

# for jobID specific pings
# my $annotationStatusChannelBase  = 'annotationStatus:';

# these keys should match the corresponding fields in the web server
# mongoose schema; TODO: at startup request file from webserver with this config
my $jobKeys = {};
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

my $configPathBaseDir = "config/";
my $configFilePathHref = {};

my $verbose = 1;

my $beanstalk = Beanstalk::Client->new({
  server    => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
  default_tube => $conf->{beanstalkd}{tubes}{annotation}{submission},
  connect_timeout => 1,
  encoder => sub { encode_json(\@_) },
  decoder => sub { @{decode_json(shift)} },
});

my $beanstalkEvents = Beanstalk::Client->new({
  server    => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
  default_tube => $conf->{beanstalkd}{tubes}{annotation}{events},
  connect_timeout => 1,
  encoder => sub { encode_json(\@_) },
  decoder => sub { @{decode_json(shift)} },
});

while(my $job = $beanstalk->reserve) {
  # Parallel ForkManager used only to throttle number of jobs run in parallel
  # cannot use run_on_finish with blocking reserves, use try catch instead
  # Also using forks helps clean up leaked memory from LMDB_File
  # Unfortunately, parallel fork manager doesn't play nicely with try tiny
  # prevents anything within the try from executing
  my $jobDataHref;
    
  try {
    say "in try";
    $jobDataHref = decode_json( $job->data );
  
    $beanstalkEvents->put({ priority => 0, data => encode_json{
      event => 'started',
      # jobId   => $jobDataHref->{_id},
      queueId => $job->id,
    }  } );

    my $statistics = handleJob($jobDataHref, $job->id);
      
    say "statistics are";
    p $statistics;
    # Signal completion before completion actually occurs via delete
    # To be conservative; since after delete message is lost
    $beanstalkEvents->put({ priority => 0, data =>  encode_json({
      event => 'completed',
      queueId => $job->id,
      # jobId   => $jobDataHref->{_id},
      result  => $statistics,
    }) } );
    
     say "completed job with queue id " . $job->id;

    $beanstalk->delete($job->id);
  } catch {
    say "job ". $job->id . " failed due to $_";
      
    # Don't store the stack
    my $reason = substr($_, 0, index($_, 'at'));

    # Signal before bury, because we always want to record that the job failed
    # even if burying fails
    $beanstalkEvents->put( { priority => 0, data => encode_json({
      event => 'failed',
      reason => $reason,
      queueId => $job->id,
    }) } );

    $job->bury;
  } 
}
 
sub handleJob {
  my $submittedJob = shift;
  my $queueId = shift;

  my $failed;

  say "in handle job, jobData is";
  p $submittedJob;

  my $jobID = $submittedJob->{id};

  say "jobID is $jobID";

  my $log_name = join '.', 'annotation', 'jobID', $jobID, 'log';
  my $log_file = File::Spec->rel2abs( ".", $log_name );
  say "writing log file here: $log_file" if $verbose;
  Log::Any::Adapter->set( 'File', $log_file );
  my $log = Log::Any->get_logger();

  my $inputHref;

  try {
    $inputHref = coerceInputs($submittedJob, $queueId);

    if ($verbose) {
      say "The user job data sent to annotator is: ";
      p $inputHref;
    }

    # create the annotator
    my $annotate_instance = Interface->new($inputHref);
    my $result            = $annotate_instance->annotate;

    # if(!defined $result) {
    #   $log->error('Nothing returned from annotator');
    #   die 'Error: Nothing returned from annotator';
    # }

    return $result;
  } catch {
    $log->error($_);

    my $indexOfConstructor = index($_, "Seq::");
    
    if(~$indexOfConstructor) {
      $failed = substr($_, 0, $indexOfConstructor);
    } else {
      my $end = length($_);
      if($end > 100) {
        $end = 100;
      }
      $failed = substr($_, 0, $end);
    }

    die $failed;
  };
}

#Here we may wish to read a json or yaml file containing argument mappings
sub coerceInputs {
  my $jobDetailsHref = shift;
  my $queueId = shift;

  my $inputFilePath  = $jobDetailsHref->{ $jobKeys->{inputFilePath} };
  my $outputFilePath = $jobDetailsHref->{ $jobKeys->{outputFilePath} };
  my $debug          = $DEBUG;                                        #not, not!

  my $configFilePath = getConfigFilePath( $jobDetailsHref->{ $jobKeys->{assembly} } );

  return {
    snpfile            => $inputFilePath,
    out_file           => $outputFilePath,
    config             => $configFilePath,
    ignore_unknown_chr => 1,
    publisher => {
      server => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
      queue  => $conf->{beanstalkd}{tubes}{annotation}{events},
      messageBase => {
        event => 'progress',
        queueId => $queueId,
        data => undef,
      }
    },
    compress => 1,
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
1;
