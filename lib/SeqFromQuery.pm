use 5.10.0;
use strict;
use warnings;

# ABSTRACT: Create an annotation from a query
package SeqFromQuery;

use Mouse 2;
our $VERSION = '0.001';

use Search::Elasticsearch;

use Path::Tiny;


use namespace::autoclean;

use DDP;

use Seq::Output::Delimiters;
# use MCE::Loop;
# use MCE::Shared;
use Seq::Statistics;
use Seq::Headers;
use Seq::InputFile;

use YAML::XS qw/LoadFile/;
use Try::Tiny;
use Cpanel::JSON::XS qw/decode_json encode_json/;

# Defines basic things needed in builder and annotator, like logPath,
extends 'Seq::Base';

# Defines most of the properties that can be configured at run time
# Needed because there are variations of Seq.pm, ilke SeqFromQuery.pm
with 'Seq::Definition';

# An archive, containing an "annotation" file
has inputQueryBody => (is => 'ro', isa => 'HashRef', required => 1);

# Probably the user id
has indexName => (is => 'ro', required => 1);

# The index type; probably the job id
has indexType => (is => 'ro', required => 1);

has assembly => (is => 'ro', isa => 'Str', required => 1);
# has commitEvery => (is => 'ro', default => 5000);

# The user may have given some header fields already
# If so, this is a re-indexing job, and we will want to append the header fields
has fieldNames => (is => 'ro', isa => 'ArrayRef', required => 1);


# TODO: TOO DRY-improper (shared with Seq.pm)
sub BUILDARGS {
  my ($self, $data) = @_;

  if($data->{temp_dir} ) {
    # It's a string, convert to path
    if(!ref $data->{temp_dir}) {
      $data->{temp_dir} = path($data->{temp_dir});
    }

    $data->{temp_dir} = $self->makeRandomTempDir($data->{temp_dir});
  }
  
  if( !$data->{logPath} ) {
    if(!ref $data->{output_file_base}) {
      $data->{output_file_base} = path($data->{output_file_base});
    }

    $data->{logPath} = $data->{output_file_base}->sibling(
      $data->{output_file_base}->basename . '.annotation-log.txt');
  }

  return $data;
};


# TODO: This is too complicated, shared with Seq.pm for the most part
sub BUILD {
  my $self = shift;

  $self->{_outDir} = $self->output_file_base->parent();

  ############################# Handle Temp Dir ################################
  # TODO: TOO DRY-nonconformant (shared with Seq.pm)
  # If we specify temp_dir, user data will be written here first, then moved to the
  # final destination
  # If we're given a temp_dir, then we need to make temporary out paths and log paths
  if($self->temp_dir) {
    # Provided by Seq::Base
    my $logPath = $self->temp_dir->child( path($self->logPath)->basename );
    
    unlink $self->logPath;

    # Updates the log path held by Seq::Role::Message static variable
    $self->setLogPath($logPath);

    $self->{_tempOutPath} = $self->temp_dir->child( $self->output_file_base->basename )->stringify;
  }

  ############### Set log, annotation, statistics output basenames #####################
  my $outputFileBaseName = $self->output_file_base->basename;

  if(!$self->output_file_base->parent->exists) {
    $self->output_file_base->parent->mkpath;
  }

  $self->outputFilesInfo->{log} = path($self->logPath)->basename;
  $self->outputFilesInfo->{annotation} = $outputFileBaseName . '.annotation.tab';

  if($self->compress) {
    $self->outputFilesInfo->{compressed} = $self->makeTarballName( $outputFileBaseName );
  }

  my $tracks = Seq::Tracks->new({tracks => $self->tracks, gettersOnly => 1});

  # We separate out the reference track getter so that we can check for discordant
  # bases, and pass the true reference base to other getters that may want it (like CADD)
  $self->{_refTrackGetter} = $tracks->getRefTrackGetter();

  my %trackNamesMap;
  for my $track (@{ $tracks->trackGetters }) {
    $trackNamesMap{$track->name} = 1;
  }

  $self->{_trackNames} = \%trackNamesMap;
  ################### Creates the output file handler #################
  $self->{_outputter} = Seq::Output->new();

  if($self->run_statistics) {
    my %args = (
      refTrackName => $self->{_refTrackGetter}->name,
      altField => $self->altField,
      homozygotesField => $self->homozygotesField,
      heterozygotesField => $self->heterozygotesField,
      outputBasePath => $self->output_file_base->stringify,
    );

    if($self->statistics) {
      %args = (%args, %{$self->statistics});
    }

    # TODO : use go-style ($err, $statisticRunner)
    my $statisticsRunner  = Seq::Statistics->new(\%args);
    
    # TODO: Move this as an export of Seq::Statistics
    $self->outputFilesInfo->{statistics} = {
      json => $statisticsRunner->jsonFilePath,
      tab => $statisticsRunner->tabFilePath,
      qc => $statisticsRunner->qcFilePath,
    };

    $self->{_statsArgs} = $statisticsRunner->getStatsArguments();
  }
}

sub annotate {
  my $self = shift;

  $self->log( 'info', 'Beginning saving annotation from query' );

  $self->log( 'info', 'Input query is: ' . encode_json($self->inputQueryBody) );

  my $alleleDelimiter = $self->{_outputter}->delimiters->alleleDelimiter;
  my $positionDelimiter = $self->{_outputter}->delimiters->positionDelimiter;
  my $valueDelimiter = $self->{_outputter}->delimiters->valueDelimiter;
  my $fieldSeparator = $self->{_outputter}->delimiters->fieldSeparator;
  my $emptyFieldChar = $self->{_outputter}->delimiters->emptyFieldChar;

  my @fieldNames = @{$self->fieldNames};;

  my @childrenOrOnly;
  $#childrenOrOnly = $#fieldNames;

  # Elastic top level of { parent => child } is parent.
  my @parentNames;
  $#parentNames = $#fieldNames;

  for my $i (0 .. $#fieldNames) {
    if( index($fieldNames[$i], '.') > -1 ) {
      my @path = split(/\./, $fieldNames[$i]);
      $parentNames[$i] = $path[0];

      if(@path == 2) {
        $childrenOrOnly[$i] = [ $path[1] ];
      } elsif(@path > 2) {
        $childrenOrOnly[$i] = [ @path[ 1 .. $#path] ];
      }
      
    } else {
      $parentNames[$i] = $fieldNames[$i];
      $childrenOrOnly[$i] = $fieldNames[$i];
    }
  }

  ################## Make the full output path ######################
  # The output path always respects the $self->output_file_base attribute path;
  my $outputPath;

  if($self->temp_dir) {
    $outputPath = $self->temp_dir->child($self->outputFilesInfo->{annotation} );
  } else {
    $outputPath = $self->output_file_base->parent->child($self->outputFilesInfo->{annotation} );
  }

  my $outFh = $self->get_write_fh($outputPath);
  
  if(!$outFh) {
    #TODO: should we report $err? less informative, but sometimes $! reports bull
    #i.e inappropriate ioctl when actually no issue
    my $err = "Failed to open " . $self->{_tempOutPath} || $self->{outputFileBasePath};
    $self->_errorWithCleanup($err);
    return ($err, undef);
  }
  
  my $es = Search::Elasticsearch->new(nodes => [
    '172.31.62.32:9200',
  ]);

  my $scroll = $es->scroll_helper(
    size        => 1000,
    body        => $self->inputQueryBody,
    index => $self->indexName,
    type => $self->indexType,
  );

  # Stats may or may not be provided
  my $statsFh;
  my $outputHeader = join($fieldSeparator, @fieldNames);

  # Write the header

  say $outFh $outputHeader;

  # TODO: error handling if fh fails to open
  if($self->{_statsArgs}) {
    open($statsFh, "|-", $self->{_statsArgs});

    say $statsFh $outputHeader;
  }

  $self->log('info', "finished indexing");

  my $progressHandler = $self->makeLogProgress();

  while(my @docs = $scroll->next(1000)) {
    my @sourceData;
    $#sourceData = $#docs;

    my $i = 0;
    for my $doc (@docs) {
      my @rowData;
      # Initialize all values to undef
      # Output.pm requires a sparse array for any missing values
      # To preserve output order
      $#rowData = $#fieldNames;

      for my $y (0 .. $#fieldNames) {
        $rowData[$y] = _populateArrayPathFromHash($childrenOrOnly[$y], $doc->{_source}{$parentNames[$y]});
      }

      $sourceData[$i] = \@rowData;

      $i++;
    }

    my $outputString = _makeOutputString(\@sourceData, 
      $emptyFieldChar, $valueDelimiter, $positionDelimiter, $alleleDelimiter, $fieldSeparator);

    print $outFh $outputString;
    print $statsFh $outputString;

    &{$progressHandler}(scalar @docs);
  }

  # TODO: Too DRY, put into Statistics.pm
  ################ Finished writing file. If statistics, print those ##########
  my $statsHref;
  if($self->{_statsArgs}) {
    # Force the stats program to write its outputs
    close $statsFh;
    system('sync');

    $self->log('info', "Gathering statistics");

    (my $status, undef, my $jsonFh) = $self->get_read_fh($self->outputFilesInfo->{statistics}{json});

    if($status) {
      $self->log('error', $!);
    } else {
      my $jsonStr = <$jsonFh>;
      $statsHref = decode_json($jsonStr);
    }
  }

  ################ Compress if wanted ##########
  $self->_moveFilesToFinalDestinationAndDeleteTemp();

  return (undef, $statsHref, $self->outputFilesInfo);
}

sub _populateArrayPathFromHash {
  my ($pathAref, $dataForEndOfPath) = @_;
  #     $_[0]  , $_[1]    , $_[2]
  if(!ref $pathAref) {
    return $dataForEndOfPath;
  }

  for my $i (0 .. $#$pathAref) {
    $dataForEndOfPath = $dataForEndOfPath->{$pathAref->[$i]};
  }

  return $dataForEndOfPath;
}

sub _makeOutputString {
  my ($arrayRef, $emptyFieldChar, $valueDelimiter, $positionDelimiter, $alleleDelimiter, $fieldSeparator) = @_;

  # Expects an array of row arrays, which contain an for each column, or an undefined value
  for my $row (@$arrayRef) {
    COLUMN_LOOP: for my $column (@$row) {
      # Some fields may just be missing
      if(!defined $column) {
        $column = $emptyFieldChar;
        next COLUMN_LOOP;
      }

      for my $alleleData (@$column) {
        POS_LOOP: for my $positionData (@$alleleData) {
          if(!defined $positionData) {
            $positionData = $emptyFieldChar;
            next POS_LOOP;
          }

          if(ref $positionData) {
            $positionData = join($valueDelimiter, map { $_ || $emptyFieldChar } @$positionData);
            next POS_LOOP;
          }
        }

        $alleleData = join($positionDelimiter, @$alleleData);
      }

      $column = join($alleleDelimiter, @$column);
    }

    $row = join($fieldSeparator, @$row);
  }

  return join("\n", @$arrayRef);
}

sub makeLogProgress {
  my $self = shift;

  my $total = 0;

  my $hasPublisher = $self->hasPublisher;

  if(!$hasPublisher) {
    # noop
    return sub{};
  }

  return sub {
    #my $progress = shift;
    ##    $_[0] 

    if(defined $_[0]) {

      $total += $_[0];

      $self->publishProgress($total);
      return;
    }
  }
}

sub _moveFilesToFinalDestinationAndDeleteTemp {
  my $self = shift;

  my $compressErr;

  if($self->compress) {
    $compressErr = $self->compressDirIntoTarball(
      $self->temp_dir || $self->{_outDir}, $self->outputFilesInfo->{compressed} );

    if($compressErr) {
      return $self->_errorWithCleanup("Failed to compress output files because: $compressErr");
    }
  }

  my $finalDestination = $self->{_outDir};

  if($self->temp_dir) {
    my $mvCommand = $self->delete_temp ? 'mv' : 'cp';
    
    $self->log('info', "Putting output file into final destination on EFS or S3 using $mvCommand");

    my $result;

    if($self->compress) {
      my $sourcePath = $self->temp_dir->child( $self->outputFilesInfo->{compressed} )->stringify;
      $result = system("$mvCommand $sourcePath $finalDestination");
      
    } else {
      $result = system("$mvCommand " . $self->tempPath . "/* $finalDestination");
    }

    if($self->delete_temp) {
      $self->temp_dir->remove_tree;
    }
  
    # System returns 0 unless error
    if($result) {
      return $self->_errorWithCleanup("Failed to $mvCommand file to final destination");
    }

    $self->log("info", "Successfully used $mvCommand to place outputs into final destination");
  }

  return '';
}


sub _errorWithCleanup {
  my ($self, $msg) = @_;

  # To send a message to clean up files.
  # TODO: Need somethign better
  #MCE->gather(undef, undef, $msg);
  
  $self->log('warn', $msg);
  return $msg;
}

__PACKAGE__->meta->make_immutable;

1;
