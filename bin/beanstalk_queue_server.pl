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


use Beanstalk::Client;

use YAML::XS qw/LoadFile/;

use Seq;
# use AnyEvent;
# use AnyEvent::PocketIO::Client;
#use Sys::Info;
#use Sys::Info::Constants qw( :device_cpu )
#for choosing max connections based on available resources

# max of 1 job at a time for now

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
$jobKeys->{inputFilePath}    = 'inputFilePath';
$jobKeys->{outputFilePath} = 'outputBasePath';
$jobKeys->{assembly}       = 'assembly';
$jobKeys->{options}       = 'options';

my $configPathBaseDir = "config/";
my $configFilePathHref = {};

my $verbose = $ARGV[0];

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

my $events = $conf->{beanstalkd}{events};

while(my $job = $beanstalk->reserve) {
  # Parallel ForkManager used only to throttle number of jobs run in parallel
  # cannot use run_on_finish with blocking reserves, use try catch instead
  # Also using forks helps clean up leaked memory from LMDB_File
  # Unfortunately, parallel fork manager doesn't play nicely with try tiny
  # prevents anything within the try from executing
  
  my $jobDataHref;
  my ($err, $statistics, $outputFileNamesHashRef);

  try {
    $jobDataHref = decode_json( $job->data );
    
     # create the annotator
    my $inputHref = coerceInputs($jobDataHref, $job->id);
  
    my $configData = LoadFile($inputHref->{config});

    # Hide the server paths in the config we send back;
    # Those represent a security concern
    $configData->{files_dir} = 'hidden';

    if($configData->{temp_dir}) {
      $configData->{temp_dir} = 'hidden';
    }

    $configData->{temp_dir} = 'hidden';

    for my $track (@{$configData->{tracks}}) {
      # Finish stripping local_files of their absPaths;
      # Use Path::Tiny basename;
    }

    $beanstalkEvents->put({ priority => 0, data => encode_json{
      event => $events->{started},
      jobConfig => $configData,
      submissionID   => $jobDataHref->{submissionID},
      queueID => $job->id,
    }  } );

    my $annotate_instance = Seq->new_with_config($inputHref);
    ($err, $statistics, $outputFileNamesHashRef) = $annotate_instance->annotate();

  } catch {
    say "job ". $job->id . " failed due to $_";
      
    # Don't store the stack
    $err = $_; #substr($_, 0, index($_, 'at'));
  };

  if ($err) { 

    say "Got error, failing the job with queueID " . $job->id;

    say "job ". $job->id . " failed due to found error, which is $err";
    
    $beanstalkEvents->put( { priority => 0, data => encode_json({
      event => $events->{failed},
      reason => $err,
      queueID => $job->id,
      submissionID   => $jobDataHref->{submissionID},
    }) } );

    $job->bury; 

    next;
  }

  # Signal completion before completion actually occurs via delete
  # To be conservative; since after delete message is lost
  $beanstalkEvents->put({ priority => 0, data =>  encode_json({
    event => $events->{completed},
    queueID => $job->id,
    submissionID   => $jobDataHref->{submissionID},
    results  => {
      summary => $statistics,
      outputFileNames => $outputFileNamesHashRef,
    }
  }) } );
  
  say "completed job with queue id " . $job->id;

  $beanstalk->delete($job->id);
}

#Here we may wish to read a json or yaml file containing argument mappings
sub coerceInputs {
  my $jobDetailsHref = shift;
  my $queueId = shift;

  my $inputFilePath  = $jobDetailsHref->{ $jobKeys->{inputFilePath} };
  my $outputFilePath = $jobDetailsHref->{ $jobKeys->{outputFilePath} };
  my $debug          = $DEBUG;                                        #not, not!

  my $configFilePath = getConfigFilePath( $jobDetailsHref->{ $jobKeys->{assembly} } );

  #TODO: allow users to set options, merge with config
  return {
    input_file            => $inputFilePath,
    output_file_base           => $outputFilePath,
    config             => $configFilePath,
    ignore_unknown_chr => 1,
    publisher => {
      server => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
      queue  => $conf->{beanstalkd}{tubes}{annotation}{events},
      messageBase => {
        event => $events->{progress},
        queueID => $queueId,
        data => undef,
      }
    },
    compress => 1,
    verbose => $verbose,
    run_statistics => 1,
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
