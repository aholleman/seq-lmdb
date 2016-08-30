use 5.10.0;
use strict;
use warnings;

package Seq;

our $VERSION = '0.001';

# ABSTRACT: Annotate a snp file

use Mouse 2;
use Types::Path::Tiny qw/AbsPath AbsFile AbsDir/;
use namespace::autoclean;

use DDP;

use MCE::Loop;
use MCE::Shared;

use Seq::InputFile;
use Seq::Output;
use Seq::Headers;
use Seq::Tracks;
use Seq::Statistics;
use Seq::DBManager;
use Path::Tiny;
use Carp qw/croak/;

extends 'Seq::Base';

has snpfile => (is => 'ro', isa => AbsFile, coerce => 1, required => 1,
  handles  => { inputFilePath => 'stringify' });

has out_file => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1, 
  handles => { outputFilePath => 'stringify' });

has temp_dir => ( is => 'rw', isa => AbsDir, coerce => 1,
  handles => { tempPath => 'stringify' });

# Tracks configuration hash
has tracks => (is => 'ro', required => 1);

# The statistics package config options
has statistics => (is => 'ro');

has run_statistics => (is => 'ro', isa => 'Bool');

# Do we want to compress?
has compress => (is => 'ro');

# We also add a few of our own annotation attributes
# These will be re-used in the body of the annotation processor below
my $heterozygoteIdsKey = 'heterozygotes';
my $compoundIdsKey = 'compoundHeterozygotes';
my $homozygoteIdsKey = 'homozygotes';
my $minorAllelesKey = 'minorAlleles';

############# Private variables used by this package ###############
# Reads headers of input file, checks if it is in an ok format
my $inputFileProcessor = Seq::InputFile->new();

# Creates the output file
my $outputter = Seq::Output->new();

# Handle statistics, initialize in BUILD, needs args
my $statisticsHandler;

# We need to read from our database
my $db;

# Names and indices of input fields that will be added as the first few output fields
# Initialized after inputter reads first file line, to account for snp version diffs
my ($chrFieldIdx, $referenceFieldIdx, $positionFieldIdx, $alleleFieldIdx, $typeFieldIdx);
# Field names we'll add from our input file, to the output
my ($chrKey, $positionKey, $typeKey);
# We will get the individual genotypes of samples, and therefore need to know their indices
# This also depends on the header line
# Store the names of the samples, for output in the het/compound/homIdsKey columns
my ($sampleIDsToIndexesMap, $sampleIDaref);
# Ref track separate for others so that we can caluclate discordant bases, and 
# pass the true reference base to other getters, like CADD, that may want it
my ($refTrackGetter, $trackGettersExceptReference);

# If we specify temp_dir, user data will be written here first, then moved to the
# final destination
my $tempOutPath;

sub BUILDARGS {
  my ($self, $data) = @_;

  if($data->{temp_dir} ) {
    # It's a string, convert to path
    if(!ref $data->{temp_dir}) {
      $data->{temp_dir} = path($data->{temp_dir});
    }

    $data->{temp_dir} = $self->makeRandomTempDir($data->{temp_dir});
  }

  $data->{out_file} .= '.annotated.tab';
  $data->{logPath} .= '.annotation.log';
  
  return $data;
};

sub BUILD {
  my $self = shift;

  # Expects DBManager to have been given a database_dir
  $db = Seq::DBManager->new();
  
  # Set the lmdb database to read only, remove locking
  # We MUST make sure everything is written to the database by this point
  $db->setReadOnly(1);

  my $tracks = Seq::Tracks->new({tracks => $self->tracks, gettersOnly => 1});

  # We separate out the reference track getter so that we can check for discordant
  # bases, and pass the true reference base to other getters that may want it (like CADD)
  $refTrackGetter = $tracks->getRefTrackGetter();

  # All other tracks
  for my $trackGetter ($tracks->allTrackGetters) {
    if($trackGetter->name ne $refTrackGetter->name) {
      push @$trackGettersExceptReference, $trackGetter;
    }
  }

  # If we're given a temp_dir, then we need to make temporary out paths and log paths
  if($self->temp_dir) {
    # Provided by Seq::Base
    my $logPath = $self->temp_dir->child( path($self->logPath)->basename );
    
    unlink $self->logPath;

    $self->setLogPath($logPath);

    $tempOutPath = $self->temp_dir->child( $self->out_file->basename )->stringify;
  }
}

sub annotate_snpfile {
  my $self = shift; $self->log( 'info', 'Beginning annotation' );
  
  say "has statistics? " . $self->run_statistics;
  if($self->run_statistics) {
    $statisticsHandler = Seq::Statistics->new( { %{$self->statistics}, (
      heterozygoteIdsKey => $heterozygoteIdsKey, homozygoteIdsKey => $homozygoteIdsKey,
      minorAllelesKey => $minorAllelesKey,
    ) } );
  }
  
  # File size is available to logProgressAndStatistics
  (my $err, undef, my $fh) = $self->get_read_fh($self->inputFilePath);

  if($err) {
    $self->_errorWithCleanup($!);
    return ($!, undef);
  }
  
  my $taint_check_regex = $self->taint_check_regex; 
  my $delimiter = $self->delimiter;

  # Get the header fields we want in the output, and print the header to the output
  my $firstLine = <$fh>;

  chomp $firstLine;
  
  my @firstLine;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    @firstLine = split $delimiter, $1;
  } else {
    $self->_cleanUpFiles();

    $self->_errorWithCleanup("First line of input file has illegal characters");
    return ("First line of input file has illegal characters", undef);
  }

  $inputFileProcessor->checkInputFileHeader(\@firstLine);

  ########## Gather the input fields we want to use ################
  $chrFieldIdx = $inputFileProcessor->chrFieldIdx;
  $referenceFieldIdx = $inputFileProcessor->referenceFieldIdx;
  $positionFieldIdx = $inputFileProcessor->positionFieldIdx;
  $alleleFieldIdx = $inputFileProcessor->alleleFieldIdx;
  $typeFieldIdx = $inputFileProcessor->typeFieldIdx;

  $chrKey = $inputFileProcessor->chrFieldName;
  $positionKey = $inputFileProcessor->positionFieldName;
  $typeKey = $inputFileProcessor->typeFieldName;

  ######### Build the header, and write it as the first line #############
  my $headers = Seq::Headers->new();

  # Prepend these fields to the header
  $headers->addFeaturesToHeader( [$chrKey, $positionKey, $typeKey, $heterozygoteIdsKey,
    $homozygoteIdsKey, $compoundIdsKey, $minorAllelesKey ], undef, 1);

  # Outputter needs to know which fields we're going to pass it
  $outputter->setOutputDataFieldsWanted( $headers->get() );

  # If user specified a temp output path, use that
  my $outFh = $self->get_write_fh( $tempOutPath || $self->outputFilePath );

  # Write the header
  say $outFh $headers->getString();

  ############# Set the sample ids ###############
  $sampleIDsToIndexesMap = { $inputFileProcessor->getSampleNamesIdx(\@firstLine) };

  $sampleIDaref =  [ sort keys %$sampleIDsToIndexesMap ];

  my $allStatisticsHref = {};

  MCE::Loop::init {
    max_workers => 8, use_slurpio => 1, #Disable on shared storage: parallel_io => 1,
    gather => $self->logProgressAndStatistics($allStatisticsHref),
  };

  # We need to know the chunk size, and only way to do that 
  # Is to get it from within one worker, unless we use MCE::Core interface
  my $m1 = MCE::Mutex->new;
  tie my $loopErr, 'MCE::Shared', '';

  # local $SIG{__WARN__} = sub {
  #   my $message = shift;

  #   $self->_cleanUpFiles();

  #   # MCE::Loop::finish;
  # }

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    my @lines;

    open my $MEM_FH, '<', $slurp_ref; binmode $MEM_FH, ':raw';

    my $lineCount = 0;
    while ( my $line = $MEM_FH->getline() ) {
      $lineCount++;

      if ($line =~ /$taint_check_regex/) {
        chomp $line;
        my @fields = split $delimiter, $line;

        if ( !defined $refTrackGetter->chromosomes->{ $fields[0] } ) {
          next;
        }

        # Don't annotate unreliable sites, no need to notify user, standard behavior
        if($fields[$typeFieldIdx] =~ "LOW" || $fields[$typeFieldIdx] =~ "MESS") {
          next;
        }

        push @lines, \@fields;
      }
    }

    close  $MEM_FH;

    if(@lines) { 
      # Annotate lines, write the data, and MCE->Gather any statistics

      #TODO: implement better error handling
      my $err = $self->annotateLines(\@lines, $outFh);

      if($err ne '') {
        $m1->synchronize( sub { $loopErr = $err });
        $mce->abort();
      }
    }
    
    # Write progress
    MCE->gather(undef, $lineCount);
  } $fh;

  # MCE::Loop::finish;

  if($loopErr) {
    $self->_cleanUpFiles();
    return ($loopErr, undef);
  }

  ################ Finished writing file. If statistics, print those ##########
  my $ratiosAndQcHref;

  if($statisticsHandler) {
    $self->log('info', "Gathering and printing statistics");

    $ratiosAndQcHref = $statisticsHandler->makeRatios($allStatisticsHref);

    $statisticsHandler->printStatistics($ratiosAndQcHref, $tempOutPath || $self->outputFilePath);
  }

  ################ Compress if wanted ##########
  $self->_cleanUpFiles();

  return (undef, $ratiosAndQcHref);
}

sub logProgressAndStatistics {
  my $self = shift;
  my $allStatsHref = shift;

  #my ($total, $progress, $error) = (0, 0, '');
  # my $error = '';
  my $total = 0;

  my $hasPublisher = $self->hasPublisher;

  return sub {
    #my ($statistics, $progress, $error) = @_;
    ##    $_[0]         $_[1]      $_[2]
    #We have two gather calls, one for progress, one for statistics
    #If for statistics, $_[0] will have a value

    # if(defined $_[2]) {
    #   $self->_cleanUpFiles();
    #   $db->cleanUp();
    #   MCE->abort;
      
    #   #$self->log('fatal', $_[2]);
    # }

    if(defined $_[1]) {
      if(!$hasPublisher) {
        return;
      }

      #$total += $chunkSize;
      # Can exceed total because last chunk may be over-stated in size
      # if($total > $fileSize) {
      #   $progress = 100;
      # } else {
      #   $progress = sprintf '%0.1f', ( $total / $fileSize ) * 100;
      # }

      #say "progress is $progress";
      #say "total is $total";
      #say "file size is $fileSize";]
      $total += $_[1];

      $self->publishProgress($total);
      return;
    }

    if(!$statisticsHandler) {
      return;
    }

    $statisticsHandler->accumulateValues($allStatsHref, $_[0]);
    ## Handle statistics accumulation
  }
}

# Accumulates data from the database, and writes an output string
sub annotateLines {
  my ($self, $linesAref, $outFh) = @_;

  my (@inputData, @output);
  my ($wantedChr, @positions);

  # if chromosomes are out of order, or one batch has more than 1 chr,
  # we will need to make fetches to the db before the last input record is read
  # in this case, let's accumulate the incomplete results
  my $outputString = '';

  #Note: Expects first 3 fields to be chr, position, reference
  for my $fieldsAref (@$linesAref) {
    # Chromosomes may be out of order, get data for 1 chromosome at a time
    if(!$wantedChr || $fieldsAref->[$chrFieldIdx] ne $wantedChr) {
      if(@positions) {
        # Get db data for all @positions accumulated up to this point
        #TODO: get error code, or check for presence of data
        $db->dbRead($wantedChr, \@positions); 

        # accumulate results in @output
        my $err = $self->finishAnnotatingLines($wantedChr, \@positions, \@inputData, \@output);

        if($err ne '') {
          return $err;
        }

        # TODO: better error handling
        # if(!$success) {
        #   return;
        # }
        
        # Accumulate statistics from this @output
        if($statisticsHandler) {
          MCE->gather( $statisticsHandler->countTransitionsAndTransversions(\@output) );
        }

        # Accumulate the output
        $outputString .= $outputter->makeOutputString(\@output);

        # $outputter->indexOutput(\@output);

        undef @positions; undef @output; undef @inputData;
      }

      $wantedChr = $fieldsAref->[$chrFieldIdx];
    }

    if( $fieldsAref->[$referenceFieldIdx] eq $fieldsAref->[$alleleFieldIdx] ) {
      next;
    }
  
    #push the 1-based poisition in the input file into our accumulator
    #store the position of 0-based, because our database is 0-based
    #will be given to the dbRead function to bulk-get database records
    push @positions, $fieldsAref->[$positionFieldIdx] - 1;
    
    #store a reference to the current input line
    #so that we can use whatever fields we need
    push @inputData, $fieldsAref; 
  }

  # Leftovers
  if(@positions) {
    # Positions will be fille with data
    $db->dbRead($wantedChr, \@positions, 1); 

    my $err = $self->finishAnnotatingLines($wantedChr, \@positions, \@inputData, \@output);

    if($err ne '') {
      return $err;
    }
    
    undef @positions; undef @inputData;
  }

  if($statisticsHandler) {
    MCE->gather( $statisticsHandler->countTransitionsAndTransversions(\@output) );
  }

  # write everything for this part
  # This should come last, makeOutputString may mutate @output
  MCE->print($outFh, $outputString . $outputter->makeOutputString(\@output) );
  # $outputter->indexOutput(\@output);
  undef @output;

  # 0 indicates success
  # TODO: figure out better way to shut down MCE workers than die'ing (implement exit status 0)
  return '';
}

###Private genotypes: used to decide whether sample is het, hom, or compound###
my %hets = (K => 1,M => 1,R => 1,S => 1,W => 1,Y => 1,E => 1,H => 1);
my %homs = (A => 1,C => 1,G => 1,T => 1,D => 1,I => 1);
my %iupac = (A => 'A', C => 'C', G => 'G',T => 'T',D => '-',I => '+', R => 'AG',
  Y => 'CT',S => 'GC',W => 'AT',K => 'GT',M => 'AC',E => '-*',H => '+*');

#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub finishAnnotatingLines {
  my ($self, $chr, $dataFromDbAref, $inputAref, $outAref) = @_;

  my $refTrackName = $refTrackGetter->name;

  # Cache $alleles; even in long running process this is desirable
  state $cached;
  
  for (my $i = 0; $i < @$inputAref; $i++) {
    if(!defined $dataFromDbAref->[$i] ) {
      return $self->_errorWithCleanup("$chr: $inputAref->[$i][1] not found. Wrong assembly?");
    }

    $outAref->[$i]{$refTrackName} = $refTrackGetter->get($dataFromDbAref->[$i]);

    # The reference base we found on this line in the input file
    my $givenRef = $inputAref->[$i][$referenceFieldIdx];

    # May not match the reference assembly
    if( $outAref->[$i]{$refTrackName} ne $givenRef) {
      next;
      #$self->log('warn', "Reference discordant @ $inputAref->[$i][$chrFieldIdx]\:$inputAref->[$i][$positionFieldIdx]");
    }

    ############### Gather genotypes ... cache to avoid re-work ###############
    if(!defined $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] } ) {
      my @alleles;
      for my $allele ( split(',', $inputAref->[$i][$alleleFieldIdx] ) ) {
        if($allele ne $givenRef) { push @alleles, $allele; }
      }

      # If have only one allele, pass on only one allele
      $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] } = @alleles == 1 ? $alleles[0] : \@alleles;
    }

    ############# Store chr, position, alleles, type, and minor alleles ###############

    $outAref->[$i]{$chrKey} = $inputAref->[$i][$chrFieldIdx];
    $outAref->[$i]{$positionKey} = $inputAref->[$i][$positionFieldIdx];
    $outAref->[$i]{$typeKey} = $inputAref->[$i][$typeFieldIdx];

    $outAref->[$i]{$minorAllelesKey} = $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] };
 
    ############### Gather all track data (besides reference) #################
    foreach(@$trackGettersExceptReference) {
      # Pass: dataFromDatabase, chromosome, position, real reference, alleles
      $outAref->[$i]{$_->name} = $_->get(
        $dataFromDbAref->[$i], $chr, $outAref->[$i]{$positionKey}, $outAref->[$i]{$refTrackName},
        $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] } );
    };

    ############ Store homozygotes, heterozygotes, compoundHeterozygotes ########

    # We call those matching the reference that we have hets or homos, 
    # not the reference given in the input file
    SAMPLE_LOOP: for my $id ( @$sampleIDaref ) {
      my $geno = $inputAref->[$i][ $sampleIDsToIndexesMap->{$id} ];

      if( $geno eq 'N' || $geno eq $outAref->[$i]{$refTrackName} ) {
        next SAMPLE_LOOP;
      }

      if ( exists $hets{$geno} ) {
        push @{$outAref->[$i]{$heterozygoteIdsKey} }, $id;

        if( index($iupac{$geno}, $inputAref->[$i][$referenceFieldIdx] ) == -1 ) {
          push @{ $outAref->[$i]{$compoundIdsKey} }, $id;
        }
      } elsif( exists $homs{$geno} ) {
        push @{ $outAref->[$i]{$homozygoteIdsKey} }, $id;
      } else {
        $self->log( 'warn', "$geno wasn't homozygous or heterozygous" );
      }
    }
  }

  # 0 status indicates success
  return '';
}

sub _cleanUpFiles {
  my $self = shift;

  my $compressedOutPath;

  if($self->compress) {
    $self->log('info', "Compressing output");
    $compressedOutPath = $self->compressPath( $tempOutPath || $self->out_file);
  }

  my $finalDestination;

  if($self->temp_dir) {
    $self->log('info', 'Moving output file to final destination on NFS (EFS) or S3');

    my $result;
    if($compressedOutPath) {
      my $compressedFileName = path($compressedOutPath)->basename;

      my $source = $self->temp_dir->child($compressedFileName);
      
      $finalDestination = $self->out_file->parent->child($compressedFileName );

      $result = system("mv $source $finalDestination");
    } else {
      $finalDestination = $self->out_file->parent;
      $result = system("mv " . $self->tempPath . "/* $finalDestination");
    }

    $self->temp_dir->remove_tree;

    # System returns 0 unless error
    if($result) {
      return $self->_errorWithCleanup("Failed to move file to final destination");
    }

    $self->log("info", 'Moved outputs into final desitnation');
  } else {
    ## TODO: TEST unlink out file and everything associated
    $self->out_file->parent->remove_tree;
  }

  return '';
}

# This function is expected to run within a fork, so itself it doesn't clean up 
# files
# TODO: better error handling
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
