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
state $heterozygoteIdsKey = 'heterozygotes';
state $compoundIdsKey = 'compoundHeterozygotes';
state $homozygoteIdsKey = 'homozygotes';
state $minorAllelesKey = 'minorAlleles';

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
  $self->{_db} = Seq::DBManager->new();
  
  # Set the lmdb database to read only, remove locking
  # We MUST make sure everything is written to the database by this point
  $self->{_db}->setReadOnly(1);

  my $tracks = Seq::Tracks->new({tracks => $self->tracks, gettersOnly => 1});

  # We separate out the reference track getter so that we can check for discordant
  # bases, and pass the true reference base to other getters that may want it (like CADD)
  $self->{_refTrackGetter} = $tracks->getRefTrackGetter();

  # All other tracks
  for my $trackGetter ($tracks->allTrackGetters) {
    if($trackGetter->name ne $self->{_refTrackGetter}->name) {
      push @{ $self->{_trackGettersExceptReference} }, $trackGetter;
    }
  }

  # If we specify temp_dir, user data will be written here first, then moved to the
  # final destination
  # If we're given a temp_dir, then we need to make temporary out paths and log paths
  if($self->temp_dir) {
    # Provided by Seq::Base
    my $logPath = $self->temp_dir->child( path($self->logPath)->basename );
    
    unlink $self->logPath;

    $self->setLogPath($logPath);

    $self->{_tempOutPath} = $self->temp_dir->child( $self->out_file->basename )->stringify;
  }

  # Creates the output file
  $self->{outputter} = Seq::Output->new();

  # Handles statistics if requested at construction time
  if($self->run_statistics) {
    $self->{statisticsHandler} = Seq::Statistics->new( { %{$self->statistics}, (
      heterozygoteIdsKey => $heterozygoteIdsKey, homozygoteIdsKey => $homozygoteIdsKey,
      minorAllelesKey => $minorAllelesKey,
    ) } );
  }
}

sub annotate_snpfile {
  my $self = shift; $self->log( 'info', 'Beginning annotation' );
  
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

  my $inputFileProcessor = Seq::InputFile->new();

  $inputFileProcessor->checkInputFileHeader(\@firstLine);  

  ########## Gather the input fields we want to use ################
  # Names and indices of input fields that will be added as the first few output fields
  # Initialized after inputter reads first file line, to account for snp version diffs
  $self->{_chrFieldIdx} = $inputFileProcessor->chrFieldIdx;
  $self->{_referenceFieldIdx} = $inputFileProcessor->referenceFieldIdx;
  $self->{_positionFieldIdx} = $inputFileProcessor->positionFieldIdx;
  $self->{_alleleFieldIdx} = $inputFileProcessor->alleleFieldIdx;
  $self->{_typeFieldIdx} = $inputFileProcessor->typeFieldIdx;

  $self->{_chrKey} = $inputFileProcessor->chrFieldName;
  $self->{_positionKey} = $inputFileProcessor->positionFieldName;
  $self->{_typeKey} = $inputFileProcessor->typeFieldName;

  ######### Build the header, and write it as the first line #############
  my $headers = Seq::Headers->new();

  # Prepend these fields to the header
  $headers->addFeaturesToHeader( [$self->{_chrKey}, $self->{_positionKey},
    $self->{_typeKey}, $heterozygoteIdsKey, $homozygoteIdsKey, $compoundIdsKey,
    $minorAllelesKey ], undef, 1);

  # Outputter needs to know which fields we're going to pass it
  $self->{outputter}->setOutputDataFieldsWanted( $headers->get() );

  # If user specified a temp output path, use that
  my $outFh = $self->get_write_fh( $self->{_tempOutPath} || $self->outputFilePath );

  # Write the header
  say $outFh $headers->getString();

  ############# Set the sample ids ###############
  $self->{_sampleIDsToIndexesMap} = { $inputFileProcessor->getSampleNamesIdx(\@firstLine) };
  $self->{_sampleIDaref} =  [ sort keys %{ $self->{_sampleIDsToIndexesMap} } ];

  my $allStatisticsHref = {};

  my $return = MCE::Loop::init {
    max_workers => 8, use_slurpio => 1, #Disable on shared storage: parallel_io => 1,
    chunk_size => 8192,
    gather => $self->logProgressAndStatistics($allStatisticsHref),
  };

  # We need to know the chunk size, and only way to do that 
  # Is to get it from within one worker, unless we use MCE::Core interface
  my $m1 = MCE::Mutex->new;
  tie my $loopErr, 'MCE::Shared', '';

  my $aborted;
  # For now doesn't seem to work properly; won't allow respawn
  # local $SIG{INT} = sub {
  #   my $message = shift;
  #   $aborted = 1;

  #   MCE->abort();
  # };

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

        if ( !defined $self->{_refTrackGetter}->chromosomes->{ $fields[0] } ) {
          next;
        }

        # Don't annotate unreliable sites, no need to notify user, standard behavior
        if($fields[$self->{_typeFieldIdx}] eq "LOW" || $fields[$self->{_typeFieldIdx}] eq "MESS") {
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

  # abortion code needs to happen here, because otherwise LMDB won't get a chance
  # to close properly
  if($aborted) {
    say "got to aborted";

    $self->temp_dir->remove_tree;

    $self->{_db}->cleanUp();

    MCE::Loop::finish;

    return ("aborted by user", undef);
  }

  if($loopErr) {
    $self->log('info', "error detected, removing temporary files");

    $self->temp_dir->remove_tree;

    $self->{_db}->cleanUp();
    # We could also move people's output files to storage,
    # but most people probably don't want that, and it costs us money to store
    # their data
    #$self->_cleanUpFiles();
    
    return ($loopErr, undef);
  }

  ################ Finished writing file. If statistics, print those ##########
  my $ratiosAndQcHref;

  if($self->{_statisticsHandler}) {
    $self->log('info', "Gathering and printing statistics");

    $ratiosAndQcHref = $self->{_statisticsHandler}->makeRatios($allStatisticsHref);

    $self->{_statisticsHandler}->printStatistics($ratiosAndQcHref, $self->{_tempOutPath} || $self->outputFilePath);
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
    #   $self->{_db}->cleanUp();
    #   MCE->abort;
      
    #   #$self->log('fatal', $_[2]);
    # }

    if(defined $_[1]) {
      if(!$hasPublisher) {
        return;
      }

      $total += $_[1];

      $self->publishProgress($total);
      return;
    }

    ## Handle statistics accumulation
    if($self->{_statisticsHandler}) {
      $self->{_statisticsHandler}->accumulateValues($allStatsHref, $_[0]);
    }
  }
}

# Accumulates data from the database, and writes an output string
sub annotateLines {
  my ($self, $linesAref, $outFh) = @_;

  my (@inputData, @output, $wantedChr, @positions);

  # if chromosomes are out of order, or one batch has more than 1 chr,
  # we will need to make fetches to the db before the last input record is read
  # in this case, let's accumulate the incomplete results
  my $outputString = '';

  #Note: Expects first 3 fields to be chr, position, reference
  for my $fieldsAref (@$linesAref) {
    # Chromosomes may be out of order, get data for 1 chromosome at a time
    if(!$wantedChr || $fieldsAref->[$self->{_chrFieldIdx}] ne $wantedChr) {
      if(@positions) {
        # Get db data for all @positions accumulated up to this point
        #TODO: get error code, or check for presence of data
        $self->{_db}->dbRead($wantedChr, \@positions); 

        # accumulate results in @output
        my $err = $self->finishAnnotatingLines($wantedChr, \@positions, \@inputData, \@output);

        if($err ne '') {
          return $err;
        }
        
        # Accumulate statistics from this @output
        if($self->{_statisticsHandler}) {
          MCE->gather( $self->{_statisticsHandler}->countTransitionsAndTransversions(\@output) );
        }

        # Accumulate the output
        $outputString .= $self->{outputter}->makeOutputString(\@output);

        # $self->{outputter}->indexOutput(\@output);

        undef @positions; undef @output; undef @inputData;
      }

      $wantedChr = $fieldsAref->[$self->{_chrFieldIdx}];
    }

    if( $fieldsAref->[$self->{_referenceFieldIdx}] eq $fieldsAref->[$self->{_alleleFieldIdx}] ) {
      next;
    }
  
    #push the 1-based poisition in the input file into our accumulator
    #store the position of 0-based, because our database is 0-based
    #will be given to the dbRead function to bulk-get database records
    push @positions, $fieldsAref->[$self->{_positionFieldIdx}] - 1;
    
    #store a reference to the current input line
    #so that we can use whatever fields we need
    push @inputData, $fieldsAref; 
  }

  # Leftovers
  if(@positions) {
    # Positions will be fille with data
    $self->{_db}->dbRead($wantedChr, \@positions, 1); 

    my $err = $self->finishAnnotatingLines($wantedChr, \@positions, \@inputData, \@output);

    if($err ne '') {
      return $err;
    }
    
    undef @positions; undef @inputData;
  }

  if($self->{_statisticsHandler}) {
    MCE->gather( $self->{_statisticsHandler}->countTransitionsAndTransversions(\@output) );
  }

  # write everything for this part
  # This should come last, makeOutputString may mutate @output
  MCE->print($outFh, $outputString . $self->{outputter}->makeOutputString(\@output) );
  # $self->{outputter}->indexOutput(\@output);
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

  my $refTrackName = $self->{_refTrackGetter}->name;

  # Cache $alleles; even in long running process this is desirable
  state $cached;
  
  for (my $i = 0; $i < @$inputAref; $i++) {
    if(!defined $dataFromDbAref->[$i] ) {
      return $self->_errorWithCleanup("$chr: $inputAref->[$i][1] not found. Wrong assembly?");
    }

    $outAref->[$i]{$refTrackName} = $self->{_refTrackGetter}->get($dataFromDbAref->[$i]);

    # The reference base we found on this line in the input file
    my $givenRef = $inputAref->[$i][$self->{_referenceFieldIdx}];

    # May not match the reference assembly
    # TODO: What should we do with discordant sites?
    if( $outAref->[$i]{$refTrackName} ne $givenRef) {
      next;
      #$self->log('warn', "Reference discordant @ $inputAref->[$i][$self->{_chrFieldIdx}]\:$inputAref->[$i][$self->{_positionFieldIdx}]");
    }

    ############### Gather genotypes ... cache to avoid re-work ###############
    if(!defined $cached->{$givenRef}{ $inputAref->[$i][$self->{_alleleFieldIdx}] } ) {
      my @alleles;
      for my $allele ( split(',', $inputAref->[$i][$self->{_alleleFieldIdx}] ) ) {
        if($allele ne $givenRef) { push @alleles, $allele; }
      }

      # If have only one allele, pass on only one allele
      $cached->{$givenRef}{ $inputAref->[$i][$self->{_alleleFieldIdx}] } = @alleles == 1 ? $alleles[0] : \@alleles;
    }

    ############# Store chr, position, alleles, type, and minor alleles ###############

    $outAref->[$i]{$self->{_chrKey}} = $inputAref->[$i][$self->{_chrFieldIdx}];
    $outAref->[$i]{$self->{_positionKey}} = $inputAref->[$i][$self->{_positionFieldIdx}];
    $outAref->[$i]{$self->{_typeKey}} = $inputAref->[$i][$self->{_typeFieldIdx}];

    $outAref->[$i]{$minorAllelesKey} = $cached->{$givenRef}{ $inputAref->[$i][$self->{_alleleFieldIdx}] };
 
    ############### Gather all track data (besides reference) #################
    foreach(@{ $self->{_trackGettersExceptReference} }) {
      # Pass: dataFromDatabase, chromosome, position, real reference, alleles
      $outAref->[$i]{$_->name} = $_->get(
        $dataFromDbAref->[$i], $chr, $outAref->[$i]{$self->{_positionKey}}, $outAref->[$i]{$refTrackName},
        $outAref->[$i]{$minorAllelesKey} );
    };

    ############ Store homozygotes, heterozygotes, compoundHeterozygotes ########

    # We call those matching the reference that we have hets or homos, 
    # not the reference given in the input file
    SAMPLE_LOOP: for my $id ( @{ $self->{_sampleIDaref} } ) {
      my $geno = $inputAref->[$i][ $self->{_sampleIDsToIndexesMap}->{$id} ];

      if( $geno eq 'N' || $geno eq $outAref->[$i]{$refTrackName} ) {
        next SAMPLE_LOOP;
      }

      if ( exists $hets{$geno} ) {
        push @{$outAref->[$i]{$heterozygoteIdsKey} }, $id;

        if( index($iupac{$geno}, $inputAref->[$i][$self->{_referenceFieldIdx}] ) == -1 ) {
          push @{ $outAref->[$i]{$compoundIdsKey} }, $id;
        }
      } elsif( exists $homs{$geno} ) {
        push @{ $outAref->[$i]{$homozygoteIdsKey} }, $id;
      } else {
        $self->log( 'warn', "$geno wasn't homozygous or heterozygous for sample $id" );
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
    $compressedOutPath = $self->compressPath( $self->{_tempOutPath} || $self->out_file);
  }

  my $finalDestination;

  if($self->temp_dir) {
    $self->log('info', 'Moving output file to final destination on NFS (EFS) or S3');

    my $result;
    if($compressedOutPath) {
      my $compressedFileName = path($compressedOutPath)->basename;

      my $source = $self->temp_dir->child($compressedFileName);
      
      if(-e $compressedFileName && -e $source) {
        $finalDestination = $self->out_file->parent->child($compressedFileName );

        $result = system("mv $source $finalDestination");
      }
      
    } else {
      $finalDestination = $self->out_file->parent;
      if(-e $self->tempPath) {
        $result = system("mv " . $self->tempPath . "/* $finalDestination");
      }
    }

    $self->temp_dir->remove_tree;
    
    # System returns 0 unless error
    if($result) {
      return $self->_errorWithCleanup("Failed to move file to final destination");
    }

    $self->log("info", 'Moved outputs into final destination');
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
