use 5.10.0;
use strict;
use warnings;

# ABSTRACT: Create an annotation from a query
package SeqFromQuery;

use Mouse 2;
our $VERSION = '0.001';



extends 'Seq::Base';

use Search::Elasticsearch;

use Path::Tiny;
use Types::Path::Tiny qw/AbsFile AbsPath AbsDir/;



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

with 'Seq::Role::IO', 'Seq::Role::Message', 'Seq::Role::ConfigFromFile';

# The statistics package config options
# This is by default the go program we use to calculate statistics
has statisticsProgramPath => (is => 'ro', default => 'seqant-statistics');

# An archive, containing an "annotation" file
has inputQueryBody => (is => 'ro', isa => 'HashRef', required => 1);

has config => (is => 'ro', isa=> AbsFile, coerce => 1, required => 1, handles => {
  configPath => 'stringify',
});

has publisher => (is => 'ro');

has logPath => (is => 'ro', isa => AbsPath, coerce => 1);

has debug => (is => 'ro');

has verbose => (is => 'ro');

# Probably the user id
has indexName => (is => 'ro', required => 1);

# The index type; probably the job id
has indexType => (is => 'ro', required => 1);

has assembly => (is => 'ro', isa => 'Str', required => 1);
# has commitEvery => (is => 'ro', default => 5000);

# If inputFileNames provided, inputDir is required
# has inputDir => (is => 'ro', isa => AbsDir, coerce => 1);

# The user may have given some header fields already
# If so, this is a re-indexing job, and we will want to append the header fields
has fieldNames => (is => 'ro', isa => 'ArrayRef', required => 1);

# output_file_base contains the absolute path to a file base name
# Ex: /dir/child/BaseName ; BaseName is appended with .annotated.tab , .annotated-log.txt, etc
# for the various outputs
has output_file_base => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1, 
  handles => { outputFileBasePath => 'stringify' });

has temp_dir => ( is => 'ro', isa => AbsDir, coerce => 1,
  handles => { tempPath => 'stringify' });

# Tracks configuration hash. This usually comes from a YAML config file (i.e hg38.yml)
has tracks => (is => 'ro', required => 1);

# The statistics configuration options, usually defined in a YAML config file
has statistics => (is => 'ro');

# Users may not need statistics
has run_statistics => (is => 'ro', isa => 'Bool', default => 1);

# Do we want to compress?
has compress => (is => 'ro', default => 1);

# We may not want to delete our temp files
has delete_temp => (is => 'ro', default => 1);

############################ Private ###################################
# Constructed at build time from the out_file; this is given to other packages
# Like the statistics package to make its output paths
has _outputFileBaseName => (is => 'ro', init_arg => undef);

#@ params
# <Object> filePaths @params:
  # <String> compressed : the name of the compressed folder holding annotation, stats, etc (only if $self->compress)
  # <String> converted : the name of the converted folder
  # <String> annnotation : the name of the annotation file
  # <String> log : the name of the log file
  # <Object> stats : the { statType => statFileName } object
# Allows us to use all to to extract just the file we're interested from the compressed tarball
has outputFilesInfo => (is => 'ro', init_arg => undef, default => sub{ {} } );

has heterozygoteIdsKey => (is => 'ro', default => 'heterozygotes');
has homozygoteIdsKey => (is => 'ro', default => 'homozygotes');
has minorAllelesKey => (is => 'ro', default => 'minorAlleles');
has discordantKey => (is => 'ro', default => 'discordant');

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

sub BUILD {
  my $self = shift;

  $self->{_outDir} = $self->output_file_base->parent();

  ############################# Handle Temp Dir ################################
  
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

  if($self->run_statistics) {
    $self->outputFilesInfo->{statistics} = {
      json => $outputFileBaseName . '.statistics.json',
      tab => $outputFileBaseName . '.statistics.tab',
      qc => $outputFileBaseName . '.statistics.qc.tab',
    };
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

  # my @headers = @{ $self->{_headers}->getOrderedHeaderNoMap() };

  my $statsDir;
  if($self->run_statistics) {
    # Output header used to figure out the indices of the fields of interest
    (my $err, my $statsArgs, $statsDir) = $self->_prepareStatsArguments();

    if($err) {
      $self->log('warn', $err);
      return ($err, undef, undef);
    }

    open($statsFh, "|-", $statsArgs);

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

  ################ Finished writing file. If statistics, print those ##########
  my $statsHref;
  if($self->run_statistics) {
    # Force the stats program to write its outputs
    close $statsFh;
    system('sync');
    
    $self->log('info', "Gathering statistics");

    (my $status, undef, my $jsonFh) = $self->get_read_fh(
      $statsDir->child($self->outputFilesInfo->{statistics}{json})
    );

    if($status) {
      $self->log('warn', $!);
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

sub _prepareStatsArguments {
  my $self = shift;
  my $statsProg = which($self->statisticsProgramPath);

  if (!$statsProg) {
    return ("Couldn't find statistics program at " . $self->statisticsProgramPath)
  }

  # Accumulate the delimiters: Note that $alleleDelimiter isn't necessary
  # because the seqant_statistics scrip never operates on multiallelic sites
  my $valueDelimiter = $self->{_outputter}->delimiters->valueDelimiter;

  my $fieldSeparator = $self->{_outputter}->delimiters->fieldSeparator;
  my $emptyFieldString = $self->{_outputter}->delimiters->emptyFieldChar;

  my $refColumnName = $self->{_refTrackGetter}->name;
  my $alleleColumnName = $self->minorAllelesKey;
  my $siteTypeColumnName = $self->statistics->{site_type_column_name};
  
  my $homozygotesColumnName = $self->homozygoteIdsKey;
  my $heterozygotesColumnName = $self->heterozygoteIdsKey;

  my $dir = $self->temp_dir || $self->output_file_base->parent;
  my $jsonOutPath = $dir->child($self->outputFilesInfo->{statistics}{json});
  my $tabOutPath = $dir->child($self->outputFilesInfo->{statistics}{tab});
  my $qcOutPath = $dir->child($self->outputFilesInfo->{statistics}{qc});

  my $snpNameColumnName = $self->statistics->{dbSNP_name_column_name};
  my $exonicAlleleFuncColumnName = $self->statistics->{exonic_allele_function_column_name};

  if (!($snpNameColumnName && $exonicAlleleFuncColumnName && $emptyFieldString && $valueDelimiter
  && $refColumnName && $alleleColumnName && $siteTypeColumnName && $homozygotesColumnName
  && $heterozygotesColumnName && $jsonOutPath && $tabOutPath && $qcOutPath)) {
    return ("Need, refColumnName, alleleColumnName, siteTypeColumnName, homozygotesColumnName,"
      . "heterozygotesColumnName, jsonOutPath, tabOutPath, qcOutPath, "
      . "primaryDelimiter, fieldSeparator, and "
      . "numberHeaderLines must equal 1 for statistics", undef, undef);
  }
  return (undef, "$statsProg -outputJSONPath $jsonOutPath -outputTabPath $tabOutPath "
    . "-outputQcTabPath $qcOutPath -referenceColumnName $refColumnName "
    . "-alleleColumnName $alleleColumnName -homozygotesColumnName $homozygotesColumnName "
    . "-heterozygotesColumnName $heterozygotesColumnName -siteTypeColumnName $siteTypeColumnName "
    . "-dbSNPnameColumnName $snpNameColumnName "
    . "-emptyFieldString \$\"$emptyFieldString\" "
    . "-exonicAlleleFunctionColumnName $exonicAlleleFuncColumnName "
    . "-primaryDelimiter \$\"$valueDelimiter\" -fieldSeparator \$\"$fieldSeparator\" ", $dir);
}
__PACKAGE__->meta->make_immutable;

1;
