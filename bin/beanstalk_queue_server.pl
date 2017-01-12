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
use Getopt::Long;

use DDP;

use Beanstalk::Client;

use YAML::XS qw/LoadFile/;

use Seq;
use SeqFromQuery;
use Path::Tiny qw/path/;
# use AnyEvent;
# use AnyEvent::PocketIO::Client;
#use Sys::Info;
#use Sys::Info::Constants qw( :device_cpu )
#for choosing max connections based on available resources

# max of 1 job at a time for now

my $DEBUG = 0;
my $conf = LoadFile('./config/queue.yaml');

# usage
my ($verbose, $type);

GetOptions(
  'v|verbose=i'   => \$verbose,
  't|type=s'     => \$type,
);

# Beanstalk servers will be sharded
my $beanstalkHost  = $conf->{beanstalk_host_1};
my $beanstalkPort  = $conf->{beanstalk_port_1};

# for jobID specific pings
# my $annotationStatusChannelBase  = 'annotationStatus:';

# The properties that we accept from the worker caller
my %requiredForAll = (
  output_file_base => 'outputBasePath',
  assembly => 'assembly',
);

# Job dependent; one of these is required by the program this worker calls
my %requiredByType = (
  'saveFromQuery' => {
    inputQueryBody => 'queryBody',
    fieldNames => 'fieldNames',
    indexName => 'indexName',
    indexType => 'indexType',
  },
  'annotation' => {
    input_file => 'inputFilePath',
  }
);

say "Running queue server of type: $type";

my $configPathBaseDir = "config/";
my $configFilePathHref = {};

my $queueConfig = $conf->{beanstalkd}{tubes}{$type};

if(!$queueConfig) {
  die "$type not recognized. Options are " . ( join(', ', @{keys %{$conf->{beanstalkd}{tubes}}} ) );
}

my $beanstalk = Beanstalk::Client->new({
  server    => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
  default_tube => $queueConfig->{submission},
  connect_timeout => 1,
  encoder => sub { encode_json(\@_) },
  decoder => sub { @{decode_json(shift)} },
});

my $beanstalkEvents = Beanstalk::Client->new({
  server    => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
  default_tube => $queueConfig->{events},
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

    if($verbose) {
      say "jobDataHref is";
      p $jobDataHref;
    }

     # create the annotator
    ($err, my $inputHref) = coerceInputs($jobDataHref, $job->id);

    if($err) {
      die $err;
    }

    my $configData = LoadFile($inputHref->{config});

    # Hide the server paths in the config we send back;
    # Those represent a security concern
    $configData->{files_dir} = 'hidden';

    if($configData->{temp_dir}) {
      $configData->{temp_dir} = 'hidden';
    }

    for my $track (@{$configData->{tracks}}) {
      # Finish stripping local_files of their absPaths;
      # Use Path::Tiny basename;
      $track = path($track)->basename;
    }

    $beanstalkEvents->put({ priority => 0, data => encode_json{
      event => $events->{started},
      jobConfig => $configData,
      submissionID   => $jobDataHref->{submissionID},
      queueID => $job->id,
    }  } );

    my $annotate_instance;

    if($type eq 'annotation') {
      $annotate_instance = Seq->new_with_config($inputHref);
    } elsif($type eq 'saveFromQuery') {
      $annotate_instance = SeqFromQuery->new_with_config($inputHref);
    }

    ($err, $statistics, $outputFileNamesHashRef) = $annotate_instance->annotate();

  } catch {
    # Don't store the stack
    $err = $_; #substr($_, 0, index($_, 'at'));
  };

  if ($err) {
    say "job ". $job->id . " failed";

    if(defined $verbose) {
      p $err;
    }

    if(ref $err eq 'Search::Elasticsearch::Error::Request') {
      # TODO: Improve error handling, this doesn't work reliably
      if($err->{status_code} == 400) {
        $err = "Query failed to parse";
      } else {
        $err = "Issue handling query";
      }
    }

    $beanstalkEvents->put( { priority => 0, data => encode_json({
      event => $events->{failed},
      reason => $err,
      queueID => $job->id,
      submissionID  => $jobDataHref->{submissionID},
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

  my $debug          = $DEBUG;                                        #not, not!

  my %args;
  my $err;

  my %jobSpecificArgs;
  for my $key (keys %requiredForAll) {
    if(!defined $jobDetailsHref->{$requiredForAll{$key}}) {
      $err = "Missing required key: $key in job message";
      return ($err, undef);
    }

    $jobSpecificArgs{$key} = $jobDetailsHref->{$requiredForAll{$key}};
  }

  my $requiredForType = $requiredByType{$type};

  for my $key (keys %$requiredForType) {
    if(!defined $jobDetailsHref->{$requiredForType->{$key}}) {
      $err = "Missing required key: $key in job message";
      return ($err, undef);
    }

    $jobSpecificArgs{$key} = $jobDetailsHref->{$requiredForType->{$key}};
  }

  my $configFilePath = getConfigFilePath($jobSpecificArgs{assembly});

  if(!$configFilePath) {
    $err = "Assembly $jobSpecificArgs{assembly} doesn't have corresponding config file";
    return ($err, undef);
  }

  my %commmonArgs = (
    config             => $configFilePath,
    publisher => {
      server => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
      queue  => $queueConfig->{events},
      messageBase => {
        event => $events->{progress},
        queueID => $queueId,
        submissionID => $jobDetailsHref->{submissionID},
        data => undef,
      }
    },
    compress => 1,
    verbose => $verbose,
    run_statistics => 1,
  );

  my %combined = (%commmonArgs, %jobSpecificArgs);

  return (undef, \%combined);
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

    die "\n\nNo config path found for the assembly $assembly. Exiting\n\n";
    #throws the error
    #should log here
  }
}
1;
