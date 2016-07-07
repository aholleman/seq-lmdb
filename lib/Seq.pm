use 5.10.0;
use strict;
use warnings;

package Seq;

our $VERSION = '0.001';

# ABSTRACT: Annotate a snp file

use Moose 2;
use MooseX::Types::Path::Tiny qw/AbsFile AbsPath/;
use namespace::autoclean;

use DDP;

use MCE::Loop;
use MCE::Shared;

use Seq::InputFile;
use Seq::Output;
use Seq::Headers;
use Seq::Tracks;
use Seq::Genotypes;
use Seq::Statistics;

extends 'Seq::Base';

has snpfile => (
  is       => 'ro',
  isa      => AbsFile,
  coerce   => 1,
  required => 1,
  handles  => { inputFilePath => 'stringify' }
);

has out_file => (
  is        => 'ro',
  isa       => AbsPath,
  coerce    => 1,
  required  => 1,
  handles   => { outputFilePath => 'stringify' }
);

# The statistics package config options
has statistics => (is => 'ro', isa => 'Maybe[HashRef]', lazy => 1, default => undef);

# Do we want to compress?
has compress => (is => 'ro', lazy => 1, default => undef);

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

# Handles figuring out genotype issues
my $genotypes = Seq::Genotypes->new();

# Handle statistics, initialize in BUILD, needs args
my $statisticsHandler;

# Names and indices of input fields that will be added as the first few output fields
my $chrFieldIdx;
my $referenceFieldIdx;
my $positionFieldIdx;
my $alleleFieldIdx;
my $typeFieldIdx;

my $chrKey;
my $positionKey;
# my $allelesKey;
my $typeKey;

# We will get the individual genotypes of samples, and therefore need to know
# Their indices
my $sampleIDsToIndexesMap;

# Store the names of the samples
my $sampleIDaref;

# Reference track and all other track getters. Reference is separate because
# It is used to calculate discordant bases, and because we pass its reference
# base to all other getters, because we don't rely on the input file reference base
my $refTrackGetter;
my $trackGettersExceptReference;

# We may want to log progress. So we'll stat the file, and chunk the input into N bytes
my $fileSize;
my $chunkSize;

# The track configuration array reference. The only required value: the tracks configuration (typically from YAML)
has tracks => (is => 'ro', isa => 'ArrayRef[HashRef]', required => 1);

sub BUILD {
  my $self = shift;

  my $tracks = Seq::Tracks->new( {tracks => $self->tracks, gettersOnly => 1} );

  # We won't be building anything, optimize locking for read (no locks)
  $self->dbReadOnly(1);

  # Set the lmdb database to read only, remove locking
  # We MUST make sure everything is written to the database by this point
  $self->setDbReadOnly(1);

  #the reference base can be used for many purposes
  #and so to benefit encapsulation, I separate it from other tracks during getting
  #this way, tracks can just accept the first four fields of the input file
  # chr, pos, ref, alleles, using the empirically found ref
  $refTrackGetter = $tracks->getRefTrackGetter();

  # All other tracks
  for my $trackGetter ($tracks->allTrackGetters) {
    if($trackGetter->name ne $refTrackGetter->name) {
      push @$trackGettersExceptReference, $trackGetter;
    }
  }
}

sub annotate_snpfile {
  my $self = shift;

  $self->log( 'info', 'Beginning annotation' );

  my $headers = Seq::Headers->new();
  
  my $fh;

  # TODO: maybe make this more configurable, take the IdsKey values from 
  # YAML
  if($self->statistics) {
    $statisticsHandler = Seq::Statistics->new( {  %{$self->statistics}, (
      heterozygoteIdsKey => $heterozygoteIdsKey,
      homozygoteIdsKey => $homozygoteIdsKey, minorAllelesKey => $minorAllelesKey,
    ) } );
  }

  ($fileSize, $fh) = $self->get_read_fh($self->inputFilePath);
    
  my $taint_check_regex = $self->taint_check_regex; 
  my $endOfLineChar = $self->endOfLineChar;
  my $delimiter = $self->delimiter;

  # Get the header fields we want in the output, and print the header to the output
  my $firstLine = <$fh>;

  chomp $firstLine;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    $firstLine = [ split $delimiter, $1 ];

    $inputFileProcessor->checkInputFileHeader($firstLine);

    $chrFieldIdx = $inputFileProcessor->chrFieldIdx;
    $referenceFieldIdx = $inputFileProcessor->referenceFieldIdx;
    $positionFieldIdx = $inputFileProcessor->positionFieldIdx;
    $alleleFieldIdx = $inputFileProcessor->alleleFieldIdx;
    $typeFieldIdx = $inputFileProcessor->typeFieldIdx;

    $chrKey = $inputFileProcessor->chrFieldName;
    $positionKey = $inputFileProcessor->positionFieldName;
    # $allelesKey = $inputFileProcessor->alleleFieldName;
    $typeKey = $inputFileProcessor->typeFieldName;

    # Prepend these input fields to the output header record
    $headers->addFeaturesToHeader( [$chrKey, $positionKey, $typeKey,
      $heterozygoteIdsKey, $homozygoteIdsKey, $compoundIdsKey, $minorAllelesKey ], undef, 1);

    # Outputter needs to know which fields we're going to pass it
    $outputter->setOutputDataFieldsWanted( $headers->get() );

    $sampleIDsToIndexesMap = { $inputFileProcessor->getSampleNamesIdx( $firstLine ) };

    $sampleIDaref =  [ sort keys %$sampleIDsToIndexesMap ];

  } else {
    $self->log('fatal', "First line of input file has illegal characters");
  }

  my $outFh = $self->get_write_fh( $self->outputFilePath );
  
  # Write the header
  say $outFh $headers->getString();

  my $allStatisticsHref = {};
  # Initialize our parallel processes; re-uses forked processes
  my $a = MCE::Loop::init {
    #slurpio is optimized with auto chunk
    chunk_size => 'auto',
    max_workers => 32,
    use_slurpio => 1,
    gather => $self->logProgressAndStatistics($allStatisticsHref),
    #doesn't seem to improve performance
    #and apparently slow on shared storage
    parallel_io => 1,
  };

  # We need to know the chunk size, and only way to do that 
  # Is to get it from within one worker, unless we use MCE::Core interface
  my $m1 = MCE::Mutex->new;
  tie $chunkSize, 'MCE::Shared', 0;

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    if(!$chunkSize) {
       $m1->synchronize( sub {
         $chunkSize = $mce->chunk_size();
      });
    }

    my @lines;

    open my $MEM_FH, '<', $slurp_ref;
    binmode $MEM_FH, ':raw';

    while ( <$MEM_FH>) {
      if (/$taint_check_regex/) {
        chomp;
        my @fields = split $delimiter, $_;

        if ( !$refTrackGetter->chrIsWanted($fields[0] ) ) {
          $self->log('info', "Didn't recognize $fields[0], skipping");
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

    # annotateLines annotates N lines, writes them to disk
    # TODO: decide whether to return statistics from here, or use MCE::Shared
    $self->annotateLines(\@lines, $outFh);

    # Write progress
    # 1 is a placedholder for some statistics hash reference
    MCE->gather(undef);
  } $fh;

  my $ratiosAndQcHref;
  if($statisticsHandler) {
    $self->log('info', "Gathering and printing statistics");

    $ratiosAndQcHref = $statisticsHandler->makeRatios($allStatisticsHref);
    $statisticsHandler->printStatistics($ratiosAndQcHref, $self->outputFilePath);
  }

  if($self->compress) {
    $self->log('info', "Compressing output");
    $self->compressPath($self->out_file);
  }

  return $ratiosAndQcHref;
}

sub logProgressAndStatistics {
  my $self = shift;
  my $allStatsHref = shift;

  my $total = 0;
  my $progress = 0;

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

  my @output;
  my @inputData;

  # if chromosomes are out of order, or one batch has more than 1 chr,
  # we will need to make fetches to the db before the last input record is read
  # in this case, let's accumulate the incomplete results
  my $outputString = '';

  my $wantedChr; 
  my @positions;

  #Note: Expects first 3 fields to be chr, position, reference
  for my $fieldsAref (@$linesAref) {
    # if chromosomes are out of order, or one batch has more than 1 chr,
    # we will need to make fetches to the db before the last input record is read
    if($wantedChr) {
      if($fieldsAref->[$chrFieldIdx] ne $wantedChr) {
        # get db data for all @positions accumulated up to this point
        my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions); 

        #it's possible that we were only asking for 1 record
        if(!ref $dataFromDatabaseAref) {
          $dataFromDatabaseAref = [$dataFromDatabaseAref];
        }

        # accumulate results in @output
        $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
          \@positions, \@output);
        
        # Accumulate statistics from this @output
        if($statisticsHandler) {
          MCE->gather( $statisticsHandler->countTransitionsAndTransversions(\@output) );
        }

        # and prepare those reults for output, save the accumulated string value
        # This should come last, makeOutputString may mutate @output
        # TODO: figure out whether we want to allow mutation (for Elasticsearch)
        $outputString .= $outputter->makeOutputString(\@output);

        #erase accumulated values; relies on finishAnnotatingLines being synchronous
        #this will let us repeat the finishAnnotatingLines process
        undef @positions;
        undef @output;
        undef @inputData;

        #grab the new allele
        $wantedChr = $wantedChr = $fieldsAref->[$chrFieldIdx];
      }
      
    } else {
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

  #finish anything left over
  if(@positions) {
    my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions, 1); 

    #it's possible that we were only asking for 1 record
    if(!ref $dataFromDatabaseAref) {
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
}

#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub finishAnnotatingLines {
  my ($self, $chr, $dataFromDbAref, $inputAref, $positionsAref, $outAref) = @_;

  state $refTrackName = $refTrackGetter->name;
  # Cache $alleles
  state $cached;

  for (my $i = 0; $i < @$inputAref; $i++) {
    if(!defined $dataFromDbAref->[$i] ) {
      $self->log('fatal', "$chr: " . $inputAref->[$i][1] . " not found.
        You may have chosen the wrong assembly.");
    }

    $outAref->[$i]{$refTrackName} = $refTrackGetter->get($dataFromDbAref->[$i]);

    my $givenRef = $inputAref->[$i][$referenceFieldIdx];

    if( $outAref->[$i]{$refTrackName} ne $givenRef) {
      $self->log('warn', "Reference discordant @ $inputAref->[$i][$chrFieldIdx]\:$inputAref->[$i][$positionFieldIdx]");
    }

    ############### Gather genotypes ... cache to avoid re-work ###############
    if(!defined $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] } ) {
      my @alleles;
      for my $allele ( split(',', $inputAref->[$i][$alleleFieldIdx] ) ) {
        if($allele ne $givenRef) {
          push @alleles, $allele;
        }
      }

      # If have only one allele, pass on only one allele
      if(@alleles == 1) {
        $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] } = $alleles[0];
      } else {
        $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] } = \@alleles;
      }
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
    # $outAref->[$i]{$allelesKey} = $inputAref->[$i][$alleleFieldIdx];
    $outAref->[$i]{$typeKey} = $inputAref->[$i][$typeFieldIdx];

    $outAref->[$i]{$minorAllelesKey} = $cached->{$givenRef}{ $inputAref->[$i][$alleleFieldIdx] };

    ############ Store homozygotes, heterozygotes, compoundHeterozygotes ########
    SAMPLE_LOOP: for my $id ( @$sampleIDaref ) {
      my $geno = $inputAref->[$i][ $sampleIDsToIndexesMap->{$id} ];

      if( $geno eq 'N' || $geno eq $givenRef ) {
        next SAMPLE_LOOP;
      }

      if ( $genotypes->isHet($geno) ) {
        push @{$outAref->[$i]{$heterozygoteIdsKey} }, $id;

        if( $genotypes->isCompoundHet($geno, $inputAref->[$i][$referenceFieldIdx] ) ) {
          push @{ $outAref->[$i]{$compoundIdsKey} }, $id;
        }
      } elsif( $genotypes->isHom($geno) ) {
        push @{ $outAref->[$i]{$homozygoteIdsKey} }, $id;
      } else {
        $self->log( 'warn', "$geno wasn't homozygous or heterozygous" );
      }

      if( $outAref->[$i]{$heterozygoteIdsKey} && @{$outAref->[$i]{$heterozygoteIdsKey}} == 1) {
         $outAref->[$i]{$heterozygoteIdsKey} = $outAref->[$i]{$heterozygoteIdsKey}[0];
      }
      if( $outAref->[$i]{$compoundIdsKey} && @{$outAref->[$i]{$compoundIdsKey}} == 1 ) {
         $outAref->[$i]{$compoundIdsKey} = $outAref->[$i]{$compoundIdsKey}[0];
      }
      if( $outAref->[$i]{$homozygoteIdsKey} && @{$outAref->[$i]{$homozygoteIdsKey}} == 1 ) {
         $outAref->[$i]{$homozygoteIdsKey} = $outAref->[$i]{$homozygoteIdsKey}[0];
      }
    }
  }

  return $outAref;
}

__PACKAGE__->meta->make_immutable;

1;
