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

use SeqElastic;

my $DEBUG = 0;
my $conf = LoadFile('./config/queue.yaml');

# Beanstalk servers will be sharded
my $beanstalkHost  = $conf->{beanstalk_host_1};
my $beanstalkPort  = $conf->{beanstalk_port_1};

# Required fields
# The annotation_file_path is constructed from inputDir, inputFileNames by SeqElastic
my @requiredJobFields = qw/indexName type inputDir inputFileNames/;

my $configPathBaseDir = "config/";
my $configFilePathHref = {};

my $verbose = $ARGV[0];

my $beanstalk = Beanstalk::Client->new({
  server    => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
  default_tube => $conf->{beanstalkd}{tubes}{index}{submission},
  connect_timeout => 1,
  encoder => sub { encode_json(\@_) },
  decoder => sub { @{decode_json(shift)} },
});

my $beanstalkEvents = Beanstalk::Client->new({
  server    => $conf->{beanstalkd}{host} . ':' . $conf->{beanstalkd}{port},
  default_tube => $conf->{beanstalkd}{tubes}{index}{events},
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
  my ($err, $fieldNames);

  try {
    $jobDataHref = decode_json( $job->data );
  
    $beanstalkEvents->put({ priority => 0, data => encode_json{
      event => 'started',
      # jobId   => $jobDataHref->{_id},
      queueId => $job->id,
    }  } );

    ($err, $fieldNames) = handleJob($jobDataHref, $job->id);
  
  } catch {
    say "job ". $job->id . " failed due to $_";
      
    # Don't store the stack
    $err = $_; #substr($_, 0, index($_, 'at'));
  };

  if ($err) { 
    say "job ". $job->id . " failed due to found error, which is $err";
    
    $beanstalkEvents->put( { priority => 0, data => encode_json({
      event => 'failed',
      reason => $err,
      queueId => $job->id,
    }) } );

    $job->bury; 

    next;
  }

  # Signal completion before completion actually occurs via delete
  # To be conservative; since after delete message is lost
  $beanstalkEvents->put({ priority => 0, data =>  encode_json({
    event => 'completed',
    queueId => $job->id,
    # jobId   => $jobDataHref->{_id},
    fieldNames => $fieldNames,
  }) } );
  
  $beanstalk->delete($job->id);

  say "completed job with queue id " . $job->id;
}
 
sub handleJob {
  my $submittedJob = shift;
  my $queueId = shift;

  my $failed;

  say "in handle job, jobData is";
  p $submittedJob;

  my ($err, $inputHref) = coerceInputs($submittedJob);

  if($err) {
    say STDERR $err;
    return ($err, undef);
  }

  say "$inputHref is";
  p $inputHref;

  my $log_name = join '.', 'index', 'indexName', $inputHref->{indexName}, 'log';
  my $logPath = File::Spec->rel2abs( ".", $log_name );
  
  say "writing beanstalk queue log file here: $logPath" if $verbose;
    
  $inputHref->{logPath} = $logPath;
  $inputHref->{verbose} = $verbose;

  if ($verbose) {
    say "The user job data sent to annotator is: ";
    p $inputHref;
  }

  # create the annotator
  my $indexer = SeqElastic->new($inputHref);
  
  return $indexer->go;
}

#Here we may wish to read a json or yaml file containing argument mappings
sub coerceInputs {
  my $jobDetailsHref = shift;

  for my $fieldName (@requiredJobFields) {
    if(!defined $jobDetailsHref->{$fieldName}) {
      say STDERR "$fieldName required";
      return ("$fieldName required", undef);
    }
  }

  return (undef, $jobDetailsHref);
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
