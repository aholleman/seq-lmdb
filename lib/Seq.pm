use 5.10.0;
use strict;
use warnings;

package Seq;

our $VERSION = '0.001';

# ABSTRACT: Annotate a snp file

# TODO: make temp_dir handling more transparent
use Mouse 2;
use Types::Path::Tiny qw/AbsPath AbsFile AbsDir/;

use namespace::autoclean;

use DDP;

# IO::FDPass recommended for MCE::Shared
# https://github.com/marioroy/mce-perl/issues/5
use IO::FDPass;
use MCE::Loop;
use MCE::Shared;

use Seq::InputFile;
use Seq::Output;
use Seq::Headers;

use Seq::DBManager;
use Path::Tiny;
use File::Which qw/which/;
use Carp qw/croak/;
use Scalar::Util qw/looks_like_number/;

use Cpanel::JSON::XS;

extends 'Seq::Base';

# We  add a few of our own annotation attributes
# These will be re-used in the body of the annotation processor below
# Users may configure these
has input_file => (is => 'rw', isa => AbsFile, coerce => 1, required => 1,
  handles  => { inputFilePath => 'stringify' }, writer => 'setInputFile');

# Defines most of the properties that can be configured at run time
# Needed because there are variations of Seq.pm, ilke SeqFromQuery.pm
# Requires logPath to be provided (currently found in Seq::Base)
with 'Seq::Definition', 'Seq::Role::Validator';

# To initialize Seq::Base with only getters
has '+gettersOnly' => (init_arg => undef, default => 1);

# TODO: further reduce complexity
sub BUILD {
  my $self = shift;

  ########### Create DBManager instance, and instantiate track singletons #########
  # Must come before statistics, which relies on a configured Seq::Tracks
  #Expects DBManager to have been given a database_dir
  $self->{_db} = Seq::DBManager->new();

  # Set the lmdb database to read only, remove locking
  # We MUST make sure everything is written to the database by this point
  # Disable this if need to rebuild one of the meta tracks, for one run
  $self->{_db}->setReadOnly(1);

  # We separate out the reference track getter so that we can check for discordant
  # bases, and pass the true reference base to other getters that may want it (like CADD)
  # Store these references as hashes, to avoid accessor penalty
  $self->{_refTrackGetter} = $self->tracksObj->getRefTrackGetter();
  $self->{_trackGettersExceptReference} = $self->tracksObj->getTrackGettersExceptReference();

  ######### Build the header, and write it as the first line #############
  my $headers = Seq::Headers->new();

  # Seqant has a single pseudo track, that is always present, regardless of whether
  # any tracks exist
  # Note: Field order is required to stay in the follwoing order, because
  # current API allows use of constant as array index:
  # these to be configured:
  # idx 0:  $self->chromField,
  # idx 1: $self->posField,
  # idx 2: $self->typeField,
  # idx 3: $self->discordantField,
  # index 4: $self->altField,
  # index 5: $self->heterozygotesField,
  # index 6: $self->homozygotesField
  $headers->addFeaturesToHeader([
    #index 0
    $self->chromField,
    #index 1
    $self->posField,
    #index 2
    $self->typeField,
    #index 3
    $self->discordantField,
    #index 4
    $self->altField,
    #index 5
    $self->heterozygotesField,
    #index 6
    $self->homozygotesField
  ], undef, 1);

  $self->{_lastHeaderIdx} = $#{$headers->get()};

  $self->{_trackIdx} = $headers->getParentFeaturesMap();

  ################### Creates the output file handler #################
  # Used in makeAnnotationString
  $self->{_outputter} = Seq::Output->new();
}

# TODO: maybe clarify interface; do we really want to return stats and _outputFilesInfo
# or just make those public attributes
sub annotate {
  my $self = shift;

  $self->log( 'info', 'Beginning annotation' );

  #################### Validate the input file ################################
  # Converts the input file if necessary
  my ($err, $updatedOrOriginalInputFilePath) = $self->validateInputFile($self->_workingDir, $self->input_file);

  if($err) {
    $self->_errorWithCleanup($err);
    return ($err, undef, undef);
  }

  $self->setInputFile($updatedOrOriginalInputFilePath);

  # File size is available to logProgressAndStatistics
  ($err, my $inputFileCompressed, my $fh) = $self->get_read_fh($self->inputFilePath);

  if($err) {
    $self->_errorWithCleanup($!);
    return ($!, undef, undef);
  }

  # Copy once to avoid accessor penalty
  my $taint_check_regex = $self->taint_check_regex;

  # Get the header fields we want in the output, and print the header to the output
  my $firstLine = <$fh>;

  chomp $firstLine;

  my @firstLine;
  if ( $firstLine =~ $taint_check_regex ) {
    #Splitting on literal character is much,much faster
    #time perl -e '$string .= "foo \t " for(1..150); for(1..100000) { split('\t', $string) }'
    #vs
    #time perl -e '$string .= "foo \t " for(1..150); for(1..100000) { split("\t", $string) }'
    @firstLine = split '\t', $1;
  } else {
    $self->_errorWithCleanup("First line of input file has illegal characters: '$firstLine'");
    return ("First line of input file has illegal characters: '$firstLine'", undef, undef);
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

  ################## Make the full output path ######################
  # The output path always respects the $self->output_file_base attribute path;
  my $outputPath = $self->_workingDir->child($self->outputFilesInfo->{annotation});

  # If user specified a temp output path, use that
  my $outFh = $self->get_write_fh( $outputPath );

  # Stats may or may not be provided
  my $statsFh;

  # Write the header
  my $headers = Seq::Headers->new();
  my $outputHeader = $headers->getString();
  say $outFh $outputHeader;

  # TODO: error handling if fh fails to open
  if($self->run_statistics) {
    my $args = $self->_statisticsRunner->getStatsArguments();
    open($statsFh, "|-", $args);

    say $statsFh $outputHeader;
  }

  ############# Set the sample ids ###############
  ($self->{_genoNames}, $self->{_genosIdx}, $self->{_confIdx}) = $inputFileProcessor->getSampleNameConfidenceIndexes(\@firstLine);
  $self->{_genosIdxRange} = [0 .. $#{$self->{_genosIdx}} ];

  # TODO: Get SIG INT handler to work, such that temp_dir gets cleaned up
  # which will happen automatically if we cleanly return from this function
  # Ctrl + C handler; doesn't seem to work properly; won't allow respawn
  # local $SIG{INT} = sub {
  #   my $message = shift;
  # };

  my $abortErr;
  MCE::Loop::init {
    max_workers => 8, use_slurpio => 1,
    # Small chunk_size progress messages take large portion of recipient's run time
    # Causing jobs to appear to take much longer to complete.
    # So in the end, we optimize for files at least ~65k lines in size, which
    # is of course a very small file size
    #parallel_io => 1,
    chunk_size => '2560k',
    gather => $self->makeLogProgressAndPrint(\$abortErr, $outFh, $statsFh),
  };

  # Store a reference; Moose/Mouse accessors aren't terribly fast
  # And this is used millions of times
  my %wantedChromosomes = %{ $self->{_refTrackGetter}->chromosomes };

  # Avoid hash lookups when possible, those are slow too
  my $typeFieldIdx = $self->{_typeFieldIdx};

  # If the file isn't compressed, MCE::Loop is faster when given a string
  # instead of a file handle
  # https://github.com/marioroy/mce-perl/issues/5
  if(!$inputFileCompressed) {
    close $fh;
    $fh = $self->inputFilePath;
  }

  # MCE::Mutex must come after any close operations on piped file handdles
  # or MCE::Shared::stop() must be called before they are closed
  # https://github.com/marioroy/mce-perl/issues/5
  # We want to check whether the program has any errors. An easy way is to
  # Return any error within the mce_loop_f
  # Doesn't work nicely if you need to return a scalar value (no export)
  # and need to call MCE::Shared::stop() to exit 

  my $m1 = MCE::Mutex->new;
  tie my $readFirstLine, 'MCE::Shared', 0;

  mce_loop_f {
    # For performance do not copy these
    #my ($mce, $slurp_ref, $chunk_id) = @_;
    #    $_[0], $_[1],     $_[2]

    my @lines;

    # Reads: open my $MEM_FH, '<', $slurp_ref; binmode $MEM_FH, ':raw';
    open my $MEM_FH, '<', $_[1]; binmode $MEM_FH, ':raw';

    # If the file isn't compressed, we pass the file path to 
    # MCE, because it is faster that way...
    # Howver, when we do that, we need to skip the header
    # Reads:                                        && chunk_id == 1) {
    if(!$inputFileCompressed && $readFirstLine == 0 && $_[2] == 1) {
      #skip first line
      my $firstLine = <$MEM_FH>;
      $m1->synchronize(sub{ $readFirstLine = 1 });
    }

    my $annotatedCount = 0;
    my $skipCount = 0;
    while ( my $line = $MEM_FH->getline() ) {
      if ($line !~ $taint_check_regex) {
        $skipCount++;
        next;
      }

      chomp $line;
      #Splitting on literal character is much,much faster
      #time perl -e '$string .= "foo \t " for(1..150); for(1..100000) { split('\t', $string) }'
      #vs
      #time perl -e '$string .= "foo \t " for(1..150); for(1..100000) { split("\t", $string) }'
      my @fields = split '\t', $line;

      if ( !$wantedChromosomes{ $fields[0] } ) {
        $skipCount++;
        next;
      }

      # Don't annotate unreliable sites, no need to notify user, standard behavior
      if($fields[$typeFieldIdx] eq "LOW" || $fields[$typeFieldIdx] eq "MESS") {
        $skipCount++;
        next;
      }

      push @lines, \@fields;

      $annotatedCount++;
    }

    close  $MEM_FH;

    my $err = '';
    my $outString;

    if(@lines) {
      #TODO: implement better error handling
      ($err, $outString) = $self->makeAnnotationString(\@lines);
    }

    # Write progress
    MCE->gather($annotatedCount, $skipCount, $err, $outString);

    if($err) {
      $_[0]->abort();
    }

  } $fh;

  MCE::Loop::finish();

  # This removes the content of $abortErr
  # https://metacpan.org/pod/MCE::Shared
  # Needed to exit, and close piped file handles
  MCE::Shared::stop();

  # Unfortunately, MCE::Shared::stop() removes the value of $abortErr
  # according to documentation, and I did not see mention of a way
  # to copy the data from a scalar, and don't want to use a hash for this alone
  # So, using a scalar ref to abortErr in the gather function.
  if($abortErr) {
    say "Aborted job";

    # Database & tx need to be closed
    $self->{_db}->cleanUp();

    return ('Job aborted due to error', undef, undef);
  }

  ################ Finished writing file. If statistics, print those ##########
  my $statsHref;
  if($statsFh) {
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
  $err = $self->_moveFilesToOutputDir();

  # If we have an error moving the output files, we should still return all data
  # that we can
  if($err) {
    $self->log('error', $err);
  }

  $self->{_db}->cleanUp();

  return ($err || undef, $statsHref, $self->outputFilesInfo);
}

sub makeLogProgressAndPrint {
  my ($self, $abortErrRef, $outFh, $statsFh) = @_;

  my $totalAnnotated = 0;
  my $totalSkipped = 0;

  my $hasPublisher = $self->hasPublisher;

  return sub {
    #my $annotatedCount, $skipCount, $err, $outputLines = @_;
    ##    $_[0],          $_[1],     $_[2], $_[3]

    if(defined $_[2]) {
      $$abortErrRef = $_[2];
      return;
    }

    if($hasPublisher) {
      $totalAnnotated += $_[0];
      $totalSkipped += $_[1];
      $self->publishProgress($totalAnnotated, $totalSkipped);
    }

    if($statsFh) {
      print $statsFh $_[3];
    }

    print $outFh $_[3];
  }
}

# Accumulates data from the database, and returns an output string
sub makeAnnotationString {
  my ($self, $linesAref) = @_;

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
        my $err = $self->addTrackData($wantedChr, \@positions, \@inputData, \@output);

        if($err ne '') {
          return ($err, undef);
        }

        # Accumulate the output
        $outputString .= $self->{_outputter}->makeOutputString(\@output);

        undef @positions; undef @output; undef @inputData;
      }

      $wantedChr = $fieldsAref->[$self->{_chrFieldIdx}];
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

    my $err = $self->addTrackData($wantedChr, \@positions, \@inputData, \@output);

    if($err ne '') {
      return ($err, undef);
    }

    undef @positions; undef @inputData;
  }

  # 0 indicates success
  # TODO: figure out better way to shut down MCE workers than die'ing (implement exit status 0)
  return (undef, $outputString . $self->{_outputter}->makeOutputString(\@output));
}

###Private genotypes: used to decide whether sample is het, hom, or compound###
my %hets = (K => 1,M => 1,R => 1,S => 1,W => 1,Y => 1,E => 1,H => 1);
my %homs = (A => 1,C => 1,G => 1,T => 1,D => 1,I => 1);
my %iupac = (A => 'A', C => 'C', G => 'G',T => 'T', R => 'AG', Y => 'CT',S => 'GC',
  W => 'AT',K => 'GT',M => 'AC');
my %iupacArray = (A => ['A'], C => ['C'], G => ['G'], T => ['T'], R => ['A','G'],
  Y => ['C','T'],S => ['G','C'],W => ['A','T'],K => ['G','T'],M => ['A','C']);
my %indels = (E => 1,H => 1,D => 1,I => 1);
#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub addTrackData {
  my ($self, $chr, $dataFromDbAref, $inputAref, $outAref) = @_;

  my $refTrackIdx = $self->{_trackIdx}{$self->{_refTrackGetter}->name};

  # Cache $alleles; for large jobs, or long-running environments
  # This will save us millions of split's and assignments
  # Careful, this could be a place for a subtle bug in a multi-process
  # long-running environment
  # ONLY WORKS IF WE ARE COMPARING INPUT'S Ref & Alleles columns
  state $cached = {};
  state $strCache = {};

  # We store data for each indel
  my @indelDbData;
  my @indelRef;

  # We accumulate all of our results, using alleleNumber
  # Each track get method accumulates values on its own, using this
  # to keep track of whether or not an array represents multiple alleles
  # or one allele's values for a particular field
  my $alleleIdx;
  my $inputRef;
  my $alleles;
  my $strAlleles;
  my $pos;

  POSITION_LOOP: for my $i ( 0 .. $#$inputAref ) {
    if(!defined $dataFromDbAref->[$i] ) {
      return $self->_errorWithCleanup("$chr: $inputAref->[$i][1] not found. Wrong assembly?");
    }

    my @out;
    # Set array size, initializing every value to undef
    $#out = $self->{_lastHeaderIdx};

    $outAref->[$i] = \@out;

    ############# Store chr, position, alleles, type, and discordant status ###############
    $out[0][0][0] = $inputAref->[$i][$self->{_chrFieldIdx}];

    $out[1][0][0] = $pos = $inputAref->[$i][$self->{_positionFieldIdx}];

    $out[2][0][0] = $inputAref->[$i][$self->{_typeFieldIdx}];

    $inputRef = $inputAref->[$i][$self->{_referenceFieldIdx}];

    # Record whether discordant
    $out[3][0][0] = $self->{_refTrackGetter}->get($dataFromDbAref->[$i]) ne $inputRef ? 1 : 0;

    ############### Get the minor alleles, cached to avoid re-work ###############
    # Calculate the minor alleles from the user's reference
    # It's kind of hard to know exactly what to do in discordant cases
    if( !defined $cached->{$inputRef}{ $inputAref->[$i][$self->{_alleleFieldIdx}] } ) {
      my @alleles;

      for my $allele ( split(',', $inputAref->[$i][$self->{_alleleFieldIdx}]) ) {
        if( $allele ne $inputRef ) {
          push @alleles, $allele;
        }
      }

      if(@alleles == 1) {
        $cached->{$inputRef}->{ $inputAref->[$i][$self->{_alleleFieldIdx}] } = $alleles[0];
        $strCache->{$inputRef}->{ $inputAref->[$i][$self->{_alleleFieldIdx}] } = length $alleles[0] > 1 ? substr($alleles[0], 0, 1) : $alleles[0];
      } elsif(@alleles) {
        $cached->{$inputRef}->{ $inputAref->[$i][$self->{_alleleFieldIdx}] } = \@alleles;
        $strCache->{$inputRef}->{ $inputAref->[$i][$self->{_alleleFieldIdx}] } = join('', map{
          length($_) > 1 ? substr($_, 0, 1) : $_
        } @alleles);
      } else {
        # Skip sites that have no alleles. Alternative: we could die
        # Reasons not to die: File could have a small number of discordant sites
        # Reasons not to cache: don't run an if statement for 99.9% of cases that
        # are not: (discordant + ref == alt)
        # TODO: decide if this is optimal
        $self->log('warn', "$chr: $inputAref->[$i][1] doesn't have any alleles");
        # Assign the reference here, rather than in the allele loop below, which won't be reached
        # so that people get most output we can reasonably provide
        $out[$refTrackIdx][0][0] = $inputRef;
        next POSITION_LOOP;
      }
    }

    $alleles = $cached->{$inputRef}{ $inputAref->[$i][$self->{_alleleFieldIdx}] };

    $strAlleles = $strCache->{$inputRef}{ $inputAref->[$i][$self->{_alleleFieldIdx}] };

    ############ Store homozygotes, heterozygotes, compoundHeterozygotes ########
    # Homozygotes are index 4, heterozygotes 5

    my $geno;
    my $alleleIdx;

    #TODO: Inline -C. Also, we do not need the alleleIdx == -1 check if 
    #we always have the relationship that those genotypes with confidence < .95
    #are excluded from the list of Alleles
    #This may not be true for some vcf files we choose to annotate.
    SAMPLE_LOOP: for my $y (@{$self->{_genosIdxRange}}) {
      $geno = $inputAref->[$i][ $self->{_genosIdx}[$y] ];

      #Does the sample genotype equal "N" or our assembly's reference?
      if($geno eq $inputRef || $geno eq 'N') {
        next SAMPLE_LOOP;
      }

      #Exclude low confidence calls
      #This takes a LOT of time when many samples, eats up 50% of loop time
      if($inputAref->[$i][ $self->{_confIdx}[$y] ] < .95) {
        next SAMPLE_LOOP;
      }

      if ($hets{$geno}) {
        # Is this a bi-allelic sample? if so, call that homozygous
        # Indel hets are never bi-allelic, limitation of PECaller merge script
        if($indels{$geno}) {
          # Heterozygote is column 5
          push @{$out[5][ index($strAlleles, $geno eq 'E' ? '-' : '+') ][0]}, $self->{_genoNames}[$y];
        } else {
          #There can be bi-allelic SNPs, where both calls in a het are non-reference
          for my $genoAllele ( @{$iupacArray{$geno}} ) {
            if($genoAllele ne $inputRef) {
              # Heterozygote is column 5
              push @{ $out[5][ index($strAlleles, $genoAllele) ][0] }, $self->{_genoNames}[$y];
            }
          }
        }
        # Check if the sample looks like a homozygote
      } elsif($homs{$geno}) {
        if($indels{$geno}) {
          # Homozygote is column 6
          push @{ $out[6][ index($strAlleles, $geno eq 'D' ? '-' : '+') ][0] }, $self->{_genoNames}[$y];
        } else {
          # Homozygote is column 6
          push @{$out[6][ index($strAlleles, $geno) ][0]}, $self->{_genoNames}[$y];
        }
      } else {
        $self->log( 'error', "$self->{_genoNames}[$y] wasn't homozygous or heterozygote" );
      }
    }

    # http://ideone.com/NbvlF5
    if(@indelDbData) {
      undef @indelDbData;
      undef @indelRef;
    }

    $alleleIdx = 0;
    for my $allele (ref $alleles ? @$alleles : $alleles) {
      # The minorAlleles column
      $out[4][$alleleIdx][0] = $allele;
      # If any alleles have no genotypes:
      # Hets
      $out[5][$alleleIdx] //= [undef];
      # Homozygotes
      $out[6][$alleleIdx] //= [undef];

      if(length($allele) > 1) {
        # It's a deletion
        if( looks_like_number($allele) ) {
          # If the allele is == -1, it's a single base deletion, treat like a snp
          # with a weird genotype
          if($allele < -1)  {
            # Grab everything from + 1 the already fetched position to the $pos + number of deleted bases - 1
            @indelDbData = ($pos .. $pos - (int($allele) + 2));

            $self->{_db}->dbRead($chr, \@indelDbData);

            #Note that the first position keeps the same $inputRef
            #This means in the (rare) discordant multiallelic situation, the reference
            #Will be identical between the SNP and DEL alleles
            #faster than perl-style loop (much faster than c-style)
            @indelRef = ($inputRef, map { $self->{_refTrackGetter}->get($_) } @indelDbData);

            #Add the db data that we already have for this position
            unshift @indelDbData, $dataFromDbAref->[$i];
          }
        } else {
          #It's an insertion, we always read + 1 to the position being annotated
          # which itself is + 1 from the db position, so we read  $out[1][0][0] to get the + 1 base
          @indelDbData = ( $dataFromDbAref->[$i], $self->{_db}->dbReadOne($chr, $pos) );

          #Note that the first position keeps the same $inputRef
          #This means in the (rare) discordant multiallelic situation, the reference
          #Will be identical between the SNP and DEL alleles
          @indelRef =  ( $inputRef, $self->{_refTrackGetter}->get($indelDbData[1]) );
        }
      }

       if(@indelDbData) {
        ############### Gather all track data (besides reference) #################
        for my $posIdx (0 .. $#indelDbData) {
          for my $track (@{ $self->{_trackGettersExceptReference} }) {
            $out[$self->{_trackIdx}{$track->name}] //= [];

            $track->get($indelDbData[$posIdx], $chr, $indelRef[$posIdx], $allele,
              $alleleIdx, $posIdx, $out[$self->{_trackIdx}{$track->name}]);
          }

          $out[$refTrackIdx][$alleleIdx][$posIdx] = $indelRef[$posIdx];
        }
      } else {
        for my $track (@{ $self->{_trackGettersExceptReference} }) {
          $out[$self->{_trackIdx}{$track->name}] //= [];

          $track->get($dataFromDbAref->[$i], $chr, $inputRef, $allele,
            $alleleIdx, 0, $out[$self->{_trackIdx}{$track->name}])
        }

        $out[$refTrackIdx][$alleleIdx][0] = $inputRef;
      }

      $alleleIdx++;
    }
  }

  # 0 status indicates success
  return '';
}

# This function is expected to run within a fork, so itself it doesn't clean up 
# files
# TODO: better error handling
sub _errorWithCleanup {
  my ($self, $msg) = @_;

  $self->log('error', $msg);

  $self->{_db}->cleanUp();

  return $msg;
}

__PACKAGE__->meta->make_immutable;

1;
