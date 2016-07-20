use 5.10.0;
use strict;
use warnings;

package Seq;

our $VERSION = '0.001';

# ABSTRACT: Annotate a snp file

use Mouse 2;
use Types::Path::Tiny qw/AbsPath AbsFile/;
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

extends 'Seq::Base';

has snpfile => (is => 'ro', isa => AbsFile, coerce => 1, required => 1,
  handles  => { inputFilePath => 'stringify' });

has out_file => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1, 
  handles => { outputFilePath => 'stringify' });

# Tracks configuration hash
has tracks => (is => 'ro', required => 1);

# The statistics package config options
has statistics => (is => 'ro');

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
# We may want to log progress. So we'll stat the file, and chunk the input into N bytes
my ($fileSize, $chunkSize);

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
}

sub annotate_snpfile {
  my $self = shift; $self->log( 'info', 'Beginning annotation' );
  
  if($self->statistics) {
    $statisticsHandler = Seq::Statistics->new( { %{$self->statistics}, (
      heterozygoteIdsKey => $heterozygoteIdsKey, homozygoteIdsKey => $homozygoteIdsKey,
      minorAllelesKey => $minorAllelesKey,
    ) } );
  }

  # File size is available to logProgressAndStatistics
  my $fh;
  ($fileSize, undef, $fh) = $self->get_read_fh($self->inputFilePath);

  my $taint_check_regex = $self->taint_check_regex; 
  my $delimiter = $self->delimiter;

  # Get the header fields we want in the output, and print the header to the output
  my $firstLine = <$fh>;

  chomp $firstLine;
  
  my @firstLine;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    @firstLine = split $delimiter, $1;
  } else {
    $self->log('fatal', "First line of input file has illegal characters");
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

  my $outFh = $self->get_write_fh( $self->outputFilePath );

  # Write the header
  say $outFh $headers->getString();

  ############# Set the sample ids ###############
  $sampleIDsToIndexesMap = { $inputFileProcessor->getSampleNamesIdx(\@firstLine) };

  $sampleIDaref =  [ sort keys %$sampleIDsToIndexesMap ];

  my $allStatisticsHref = {};

  MCE::Loop::init {
    max_workers => 32, use_slurpio => 1, #Disable on shared storage: parallel_io => 1,
    gather => $self->logProgressAndStatistics($allStatisticsHref),
  };

  # We need to know the chunk size, and only way to do that 
  # Is to get it from within one worker, unless we use MCE::Core interface
  my $m1 = MCE::Mutex->new;
  tie $chunkSize, 'MCE::Shared', 0;

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    if(!$chunkSize) {
       $m1->synchronize( sub { $chunkSize = $mce->chunk_size(); });
    }

    my @lines;

    open my $MEM_FH, '<', $slurp_ref; binmode $MEM_FH, ':raw';

    while ( my $line = $MEM_FH->getline() ) {
      if ($line =~ /$taint_check_regex/) {
        chomp $line;
        my @fields = split $delimiter, $line;

        if ( !$refTrackGetter->chrIsWanted($fields[0] ) ) {
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

    # Annotate lines, write the data, and MCE->Gather any statistics
    $self->annotateLines(\@lines, $outFh);

    # Write progress
    MCE->gather(undef);
  } $fh;

  ################ Finished writing file. If statistics, print those ##########
  my $ratiosAndQcHref;

  if($statisticsHandler) {
    $self->log('info', "Gathering and printing statistics");

    $ratiosAndQcHref = $statisticsHandler->makeRatios($allStatisticsHref);
    $statisticsHandler->printStatistics($ratiosAndQcHref, $self->outputFilePath);
  }

  ################ Compress if wanted ##########
  if($self->compress) {
    $self->log('info', "Compressing output");
    $self->compressPath($self->out_file);
  }

  return $ratiosAndQcHref;
}

sub logProgressAndStatistics {
  my $self = shift;
  my $allStatsHref = shift;

  my ($total, $progress) = (0, 0);

  my $hasPublisher = $self->hasPublisher;

  return sub {
    #$statistics == $_[0]
    #We have two gather calls, one for progress, one for statistics
    #If for statistics, $_[0] will have a value

    if(!$_[0]) {
      if(!$hasPublisher) {
        return;
      }

      $total += $chunkSize;
      # Can exceed total because last chunk may be over-stated in size
      if($total > $fileSize) {
        $progress = 1;
      } else {
        $progress = sprintf '%0.2f', $total / $fileSize;
      }

      $self->publishProgress($progress);
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
        my $dataFromDatabaseAref = $db->dbRead($wantedChr, \@positions); 

        # It's possible that we were only asking for 1 record
        # finishAnnotatingLines expects an array
        if(ref $dataFromDatabaseAref ne "ARRAY") {
          $dataFromDatabaseAref = [$dataFromDatabaseAref];
        }

        # accumulate results in @output
        $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
          \@positions, \@output);
        
        # Accumulate statistics from this @output
        if($statisticsHandler) {
          MCE->gather( $statisticsHandler->countTransitionsAndTransversions(\@output) );
        }

        # Accumulate the output
        $outputString .= $outputter->makeOutputString(\@output);

        # $outputter->indexOutput(\@output);

        @positions = (); @output = (); @inputData = ();
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
    my $dataFromDatabaseAref = $db->dbRead($wantedChr, \@positions, 1); 

    # finishAnnotatingLines expects an array
    if(ref $dataFromDatabaseAref ne "ARRAY") {
      $dataFromDatabaseAref = [$dataFromDatabaseAref];
    }

    $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
      \@positions, \@output);
  }

  if($statisticsHandler) {
    MCE->gather( $statisticsHandler->countTransitionsAndTransversions(\@output) );
  }

  # write everything for this part
  # This should come last, makeOutputString may mutate @output
  MCE->print($outFh, $outputString . $outputter->makeOutputString(\@output) );
  
  # $outputter->indexOutput(\@output);
}

###Private genotypes: used to decide whether sample is het, hom, or compound###
my %hets = (K => 1,M => 1,R => 1,S => 1,W => 1,Y => 1,E => 1,H => 1);
my %homs = (A => 1,C => 1,G => 1,T => 1,D => 1,I => 1);
my %iupac = (A => 'A', C => 'C', G => 'G',T => 'T',D => '-',I => '+', R => 'AG',
  Y => 'CT',S => 'GC',W => 'AT',K => 'GT',M => 'AC',E => '-*',H => '+*');

#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub finishAnnotatingLines {
  my ($self, $chr, $dataFromDbAref, $inputAref, $positionsAref, $outAref) = @_;

  state $refTrackName = $refTrackGetter->name;
  # Cache $alleles
  state $cached;

  for (my $i = 0; $i < @$inputAref; $i++) {
    if(!defined $dataFromDbAref->[$i] ) {
      $self->log('fatal', "$chr: $inputAref->[$i][1] not found. Wrong assembly?");
    }

    $outAref->[$i]{$refTrackName} = $refTrackGetter->get($dataFromDbAref->[$i]);

    # The reference base we found on this line in the input file
    my $givenRef = $inputAref->[$i][$referenceFieldIdx];

    # May not match the reference assembly
    if( $outAref->[$i]{$refTrackName} ne $givenRef) {
      $self->log('warn', "Reference discordant @ $inputAref->[$i][$chrFieldIdx]\:$inputAref->[$i][$positionFieldIdx]");
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
 
    ############### Gather all track data (besides reference) #################
    foreach(@$trackGettersExceptReference) {
      # Pass: dataFromDatabase, chromosome, position, real reference, alleles
      $outAref->[$i]{$_->name} = $_->get(
        $dataFromDbAref->[$i], $chr, $positionsAref->[$i], $outAref->[$i]{$refTrackName},
        $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] } );
    };

    ############# Store chr, position, alleles, type, and minor alleles ###############

    $outAref->[$i]{$chrKey} = $inputAref->[$i][$chrFieldIdx];
    $outAref->[$i]{$positionKey} = $inputAref->[$i][$positionFieldIdx];
    $outAref->[$i]{$typeKey} = $inputAref->[$i][$typeFieldIdx];

    $outAref->[$i]{$minorAllelesKey} = $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] };

    ############ Store homozygotes, heterozygotes, compoundHeterozygotes ########
    SAMPLE_LOOP: for my $id ( @$sampleIDaref ) {
      my $geno = $inputAref->[$i][ $sampleIDsToIndexesMap->{$id} ];

      if( $geno eq 'N' || $geno eq $givenRef ) {
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

  return $outAref;
}

__PACKAGE__->meta->make_immutable;

1;
