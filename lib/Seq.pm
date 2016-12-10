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

# IO::FDPass recommended for MCE::Shared
# https://github.com/marioroy/mce-perl/issues/5
use IO::FDPass;
use MCE::Loop;
use MCE::Shared;

use Seq::InputFile;
use Seq::Output;
use Seq::Headers;
use Seq::Tracks;
# use Seq::Statistics;
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
has heterozygoteIdsKey => (is => 'ro', default => 'heterozygotes');
has homozygoteIdsKey => (is => 'ro', default => 'homozygotes');
has minorAllelesKey => (is => 'ro', default => 'minorAlleles');
has discordantKey => (is => 'ro', default => 'discordant');

has input_file => (is => 'rw', isa => AbsFile, coerce => 1, required => 1,
  handles  => { inputFilePath => 'stringify' }, writer => 'setInputFile');

# output_file_base contains the absolute path to a file base name
# Ex: /dir/child/BaseName ; BaseName is appended with .annotated.tab , .annotated-log.txt, etc
# for the various outputs
has output_file_base => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1, 
  handles => { outputFileBasePath => 'stringify' });

#Don't handle coercion to AbsDir here,
has temp_dir => ( is => 'ro', isa => AbsDir, coerce => 1, handles => { tempPath => 'stringify' });

# Tracks configuration hash. This usually comes from a YAML config file (i.e hg38.yml)
has tracks => (is => 'ro', required => 1);

# The statistics package config options
# This is by default the go program we use to calculate statistics
has statisticsProgramPath => (is => 'ro', default => 'seqant-statistics');

# The statistics configuration options, usually defined in a YAML config file
has statistics => (is => 'ro');

# Users may not need statistics
has run_statistics => (is => 'ro', isa => 'Bool');

# Do we want to compress?
has compress => (is => 'ro');

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

with 'Seq::Role::Validator';

sub BUILDARGS {
  my ($self, $data) = @_;

  if(exists $data->{temp_dir}) {
    if(!defined $data->{temp_dir}) {
      delete $data->{temp_dir};
    } else {
      # It's a string, convert to path
      if(!ref $data->{temp_dir}) {
        $data->{temp_dir} = path($data->{temp_dir});
      }
      $data->{temp_dir} = $self->makeRandomTempDir($data->{temp_dir});
    }
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
  ########### Create DBManager instance, and instantiate track singletons #########
  # Must come before statistics, which relies on a configured Seq::Tracks
  #Expects DBManager to have been given a database_dir
  $self->{_db} = Seq::DBManager->new();
  
  # Set the lmdb database to read only, remove locking
  # We MUST make sure everything is written to the database by this point
  # Disable this if need to rebuild one of the meta tracks, for one run
  $self->{_db}->setReadOnly(1);

  my $tracks = Seq::Tracks->new({tracks => $self->tracks, gettersOnly => 1});

  # We separate out the reference track getter so that we can check for discordant
  # bases, and pass the true reference base to other getters that may want it (like CADD)
  $self->{_refTrackGetter} = $tracks->getRefTrackGetter();

  # All other tracks
  my $i = 0;
  for my $trackGetter ($tracks->allTrackGetters) {
    if($trackGetter->name ne $self->{_refTrackGetter}->name) {
      push @{ $self->{_trackGettersExceptReference} }, $trackGetter;
    } else {
      $self->{_refTrackIdx} = $i;
    }

    $i++;
  }

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

  ################### Creates the output file handler #################
  $self->{_outputter} = Seq::Output->new();  

  #################### Validate the input file ################################
  # Converts the input file if necessary
  my ($err, $updatedOrOriginalInputFilePath) = $self->validateInputFile(
    $self->temp_dir || $self->{_outDir}, $self->input_file );

  $self->setInputFile($updatedOrOriginalInputFilePath);
}

# TODO: maybe clarify interface; do we really want to return stats and outputFilesInfo
# or just make those public attributes
sub annotate {
  my $self = shift;

  $self->log( 'info', 'Beginning annotation' );
    
  # File size is available to logProgressAndStatistics
  (my $err, my $inputFileCompressed, my $fh) = $self->get_read_fh($self->inputFilePath);

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
    $self->_moveFilesToFinalDestinationAndDeleteTemp();

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

  ######### Build the header, and write it as the first line #############
  my $headers = Seq::Headers->new();

  # Prepend these fields to the header
  # Order here is important, we expect the first 7 keys to be in this order,
  # or need to modify below in finishAnnotatingLines
  $headers->addFeaturesToHeader( [
    $inputFileProcessor->chrFieldName,
    $inputFileProcessor->positionFieldName,
    $inputFileProcessor->typeFieldName,
    $self->discordantKey,
    #index 4
    $self->minorAllelesKey,
    #index 5
    $self->heterozygoteIdsKey,
    #index 6
    $self->homozygoteIdsKey], undef, 1);

  my @headers = @{$headers->get()};
  $self->{_numHeaders} = $#headers;

  my $headerMap = $headers->getParentFeaturesMap();
  for my $trackName (keys %$headerMap) {
    $self->{_trackIdx}{$trackName} = $headerMap->{$trackName}
  }
  ################## Make the full output path ######################
  # The output path always respects the $self->output_file_base attribute path;
  my $outputPath;

  if($self->temp_dir) {
    $outputPath = $self->temp_dir->child($self->outputFilesInfo->{annotation} );
  } else {
    $outputPath = $self->output_file_base->parent->child($self->outputFilesInfo->{annotation} );
  }

  # If user specified a temp output path, use that
  my $outFh = $self->get_write_fh( $outputPath );

  # Stats may or may not be provided
  my $statsFh;

  # Write the header
  my $outputHeader = $headers->getString();
  say $outFh $headers->getString();

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

  ############# Set the sample ids ###############
  ($self->{_genoNames}, $self->{_genosIdx}, $self->{_confIdx}) = $inputFileProcessor->getSampleNameConfidenceIndexes(\@firstLine);
  $self->{_genosIdxRange} = [0 .. $#{$self->{_genosIdx}} ];

  my $abortErr;

  MCE::Loop::init {
    max_workers => 8, use_slurpio => 1,
    #Disable on shared storage: 
    # parallel_io => 1,
    # auto may be faster for small files, bigger ones seem to incure
    # larger system overhead, due to more LMDB driver calls perhaps?
    # Unfortunately, if we don't use a large chunk size, progress messages
    # End up taking a large portion of the web server's/recipient's run time
    # Causing jobs to appear to take much longer to complete.
    # So in the end, we optimize for files at least ~65k lines in size, which
    # is of course a very small file size
    chunk_size => 8192,
    gather => $self->makeLogProgressAndPrint(\$abortErr, $outFh, $statsFh),
  };

  # Ctrl + C handler; doesn't seem to work properly; won't allow respawn
  # local $SIG{INT} = sub {
  #   my $message = shift;
  #   $aborted = 1;

  #   MCE->abort();
  # };

  # Store a reference; Moose/Mouse accessors aren't terribly fast
  # And this is used millions of times
  my $chromosomesHref = $self->{_refTrackGetter}->chromosomes;
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
  # tie my $abortErr, 'MCE::Shared', '';
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
    # Reads:                && chunk_id == 1 && $readFirstLine == 0) {
    if(!$inputFileCompressed && $readFirstLine == 0 && $_[2] == 1) {
      #skip first line
      my $firstLine = <$MEM_FH>;
      $m1->synchronize(sub{ $readFirstLine = 1 });
    }

    my $annotatedCount = 0;
    my $skipCount = 0;
    while ( my $line = $MEM_FH->getline() ) {
      if ($line =~ $taint_check_regex) {
        $annotatedCount++;
        
        chomp $line;
        #Splitting on literal character is much,much faster
        #time perl -e '$string .= "foo \t " for(1..150); for(1..100000) { split('\t', $string) }'
        #vs
        #time perl -e '$string .= "foo \t " for(1..150); for(1..100000) { split("\t", $string) }'
        my @fields = split '\t', $line;

        if ( !defined $chromosomesHref->{ $fields[0] } ) {
          $skipCount++;
          next;
        }

        # Don't annotate unreliable sites, no need to notify user, standard behavior
        if($fields[$typeFieldIdx] eq "LOW" || $fields[$typeFieldIdx] eq "MESS") {
          $skipCount++;
          next;
        }

        push @lines, \@fields;
      } else {
        $skipCount++;
      }
    }

    close  $MEM_FH;

    my $err = '';
    my $outString;
    
    if(@lines) {
      #TODO: implement better error handling
      ($err, $outString) = $self->annotateLinesAndPrint(\@lines);
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
    say "found abort $abortErr";

    $self->temp_dir->remove_tree;

    $self->{_db}->cleanUp();

    return ($abortErr, undef, undef);
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

sub makeLogProgressAndPrint {
  my ($self, $abortErrRef, $outFh, $statsFh) = @_;

  my $totalAnnotated = 0;
  my $totalSkipped = 0;

  my $hasPublisher = $self->hasPublisher;

  if(!$hasPublisher) {
    return sub {
      #my $annotatedCount, $skipCount, $err, $outputLines = @_;
      ##    $_[0],          $_[1],     $_[2], $_[3]
      if(defined $_[2]) {
        $$abortErrRef = $_[2];
        return;
      }

      if($statsFh) {
        print $statsFh $_[3];
      }
      
      print $outFh $_[3];
    }
  }

  return sub {
    #my $annotatedCount, $skipCount, $err, $outputLines = @_;
    ##    $_[0],          $_[1],     $_[2], $_[3]

    if(defined $_[2]) {
      $$abortErrRef = $_[2];
      return;
    }

    $totalAnnotated += $_[0];
    $totalSkipped += $_[1];
    $self->publishProgress($totalAnnotated, $totalSkipped);

   if($statsFh) {
      print $statsFh $_[3];
    }
    
    print $outFh $_[3];
  }
}

# Accumulates data from the database, and writes an output string
sub annotateLinesAndPrint {
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
        my $err = $self->finishAnnotatingLines($wantedChr, \@positions, \@inputData, \@output);

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

    my $err = $self->finishAnnotatingLines($wantedChr, \@positions, \@inputData, \@output);

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
sub finishAnnotatingLines {
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
    # Set array size
    $#out = $self->{_numHeaders};

    $outAref->[$i] = \@out;

    ############# Store chr, position, alleles, type, and discordant status ###############
    $out[0][0][0] = $inputAref->[$i][$self->{_chrFieldIdx}];
    
    $out[1][0][0] = $pos = $inputAref->[$i][$self->{_positionFieldIdx}];
    
    $out[2][0][0] = $inputAref->[$i][$self->{_typeFieldIdx}];
    
    $inputRef = $inputAref->[$i][$self->{_referenceFieldIdx}];
    # Record discordant sites
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
        $self->log('warn', "$chr: $inputAref->[$i][1] doesn't have any alleles. Wrong assembly?");
        # Assign the reference here, rather than in the allele loop below, which won't be reached
        # so that people get most output we can reasonably provide
        $out[$refTrackIdx] = $inputRef;
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
        $self->log( 'warn', "$self->{_genoNames}[$y] wasn't homozygous or heterozygote" );
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
            # If deletion is -2, position 100, deleted bases are 100, 101
            if($allele == -2) {
              @indelDbData = ($dataFromDbAref->[$i], $self->{_db}->dbReadOne($chr, $pos + 1));
            } else {
              @indelDbData = (
                $dataFromDbAref->[$i],
                # From position + 1 to position + abs(allele) - 1 == position - (-allele + 1)
                # Since positions are 1 based, equivalent to saying: $pos - 1 - (int($allele) + 1)]
                @{$self->{_db}->dbRead( $chr, [$pos .. $pos - (int($allele) + 2)] )}
              );
            }
            
            #faster than perl-style loop (much faster than c-style)
            @indelRef = map { $self->{_refTrackGetter}->get($_) } @indelDbData;
          }
        } else {
          #It's an insertion, we always read + 1 to the position being annotated
          # which itself is + 1 from the db position, so we read  $out[1][0][0] to get the + 1 base
          @indelDbData = ( $dataFromDbAref->[$i], $self->{_db}->dbReadOne($chr, $pos) );
          
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

# This function is expected to run within a fork, so itself it doesn't clean up 
# files
# TODO: better error handling
sub _errorWithCleanup {
  my ($self, $msg) = @_;

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
