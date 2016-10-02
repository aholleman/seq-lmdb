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
# use Seq::Statistics;
use Seq::DBManager;
use Path::Tiny;
use File::Which qw/which/;
use Carp qw/croak/;

use Cpanel::JSON::XS;

extends 'Seq::Base';

# We  add a few of our own annotation attributes
# These will be re-used in the body of the annotation processor below
# Users may configure these
has compoundHetorzygotesIdsKey => (is => 'ro', default => 'compoundHeterozygotes');
has heterozygoteIdsKey => (is => 'ro', default => 'heterozygotes');
has homozygoteIdsKey => (is => 'ro', default => 'homozygotes');
has minorAllelesKey => (is => 'ro', default => 'minorAlleles');

# snpfile is the input file
has snpfile => (is => 'rw', isa => AbsFile, coerce => 1, required => 1,
  handles  => { inputFilePath => 'stringify' }, writer => 'setSnpFile');

# out_file contains the absolute path to a file base name
# Ex: /dir/child/BaseName ; BaseName is appended with .annotated.tab , .annotated-log.txt, etc
# for the various outputs
has out_file => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1, 
  handles => { outputFilePath => 'stringify' });

has temp_dir => ( is => 'ro', isa => AbsDir, coerce => 1,
  handles => { tempPath => 'stringify' });

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

  if($data->{temp_dir} ) {
    # It's a string, convert to path
    if(!ref $data->{temp_dir}) {
      $data->{temp_dir} = path($data->{temp_dir});
    }

    $data->{temp_dir} = $self->makeRandomTempDir($data->{temp_dir});
  }
  
  if( !$data->{logPath} ) {
    if(!ref $data->{out_file}) {
      $data->{out_file} = path($data->{out_file});
    }

    $data->{logPath} = $data->{out_file}->sibling($data->{out_file}->basename . '.annotation-log.txt');
  }

  return $data;
};

sub BUILD {
  my $self = shift;

  # Avoid accessor lookup penalty
  $self->{_compoundHetorzygotesIdsKey} = $self->compoundHetorzygotesIdsKey;
  $self->{_heterozygoteIdsKey} = $self->heterozygoteIdsKey;
  $self->{_homozygoteIdsKey} = $self->homozygoteIdsKey;
  $self->{_minorAllelesKey} = $self->minorAllelesKey;

  ########### Create DBManager instance, and instantiate track singletons #########
  # Must come before statistics, which relies on a configured Seq::Tracks
  #Expects DBManager to have been given a database_dir
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

  $self->{_outDir} = $self->out_file->parent();

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

    $self->{_tempOutPath} = $self->temp_dir->child( $self->out_file->basename )->stringify;
  }

  ############### Set log, annotation, statistics output basenames #####################
  my $outputFileBaseName = $self->out_file->basename;

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
  my ($err, $updatedOrOriginalSnpFilePath) = $self->validateInputFile(
    $self->temp_dir || $self->{_outDir}, $self->snpfile );

  $self->setSnpFile($updatedOrOriginalSnpFilePath);
}

# TODO: maybe clarify interface; do we really want to return stats and outputFilesInfo
# or just make those public attributes
sub annotate {
  my $self = shift;

  $self->log( 'info', 'Beginning annotation' );
  
  # File size is available to logProgressAndStatistics
  (my $err, undef, my $fh) = $self->get_read_fh($self->inputFilePath);

  if($err) {
    $self->_errorWithCleanup($!);
    return ($!, undef, undef);
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

  $self->{_chrKey} = $inputFileProcessor->chrFieldName;
  $self->{_positionKey} = $inputFileProcessor->positionFieldName;
  $self->{_typeKey} = $inputFileProcessor->typeFieldName;

  ######### Build the header, and write it as the first line #############
  my $headers = Seq::Headers->new();

  # Prepend these fields to the header
  $headers->addFeaturesToHeader( [$self->{_chrKey}, $self->{_positionKey},
    $self->{_typeKey}, $self->{_heterozygoteIdsKey}, $self->{_homozygoteIdsKey},
    $self->{_compoundHetorzygotesIdsKey}, $self->{_minorAllelesKey} ], undef, 1);

  # Outputter needs to know which fields we're going to pass it
  $self->{_outputter}->setOutputDataFieldsWanted( $headers->get() );

  ################## Make the full output path ######################
  # The output path always respects the $self->out_file attribute path;
  my $outputPath;

  if($self->temp_dir) {
    $outputPath = $self->temp_dir->child($self->outputFilesInfo->{annotation} );
  } else {
    $outputPath = $self->out_file->parent->child($self->outputFilesInfo->{annotation} );
  }

  # If user specified a temp output path, use that
  my $outFh = $self->get_write_fh( $outputPath );

  # Stats may or may not be provided
  my $statsFh;

  # Write the header
  my $outputHeader = $headers->getString();
  say $outFh $headers->getString();

  if($self->run_statistics) {
    # Output header used to figure out the indices of the fields of interest
    my ($err, $statsFh) = $self->_openStatsFh($outputHeader);

    if($err) {
      $self->log('warn', $err);
      return ($err, undef, undef);
    }

    say $statsFh $outputHeader;
  }

  ############# Set the sample ids ###############
  $self->{_sampleIDsToIndexesMap} = { $inputFileProcessor->getSampleNamesIdx(\@firstLine) };
  $self->{_sampleIDaref} =  [ sort keys %{ $self->{_sampleIDsToIndexesMap} } ];


  MCE::Loop::init {
    max_workers => 8, use_slurpio => 1, #Disable on shared storage: parallel_io => 1,
    chunk_size => 8192,
    gather => $self->logProgress(),
  };

  # We need to know the chunk size, and only way to do that 
  # Is to get it from within one worker, unless we use MCE::Core interface
  my $m1 = MCE::Mutex->new;
  tie my $loopErr, 'MCE::Shared', '';

  my $aborted;
  # Ctrl + C handler; doesn't seem to work properly; won't allow respawn
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
      #TODO: implement better error handling
      my $err = $self->annotateLines(\@lines, $outFh, $statsFh);

      if($err ne '') {
        $m1->synchronize( sub { $loopErr = $err });
        $mce->abort();
      }
    }
    
    # Write progress
    MCE->gather($lineCount);
  } $fh;

  # abortion code needs to happen here, because otherwise LMDB won't get a chance
  # to close properly
  if($aborted) {
    say "got to aborted";

    $self->temp_dir->remove_tree;

    $self->{_db}->cleanUp();

    MCE::Loop::finish;

    return ("aborted by user", undef, undef);
  }

  if($loopErr) {
    $self->log('info', "error detected, removing temporary files");

    $self->temp_dir->remove_tree;

    $self->{_db}->cleanUp();
    # We could also move people's output files to storage,
    # but most people probably don't want that, and it costs us money to store
    # their data
    #$self->_cleanUpFiles();
    
    return ($loopErr, undef, undef);
  }

  ################ Finished writing file. If statistics, print those ##########
  my $statsHref;
  if($self->run_statistics) {
    # Force the stats program to write its outputs
    close($statsFh);

    $self->log('info', "Gathering statistics");

    my $jsonFh;
    if( open($jsonFh, "<", $self->outputFilesInfo->{statistics}{json}) ) {
      # $! will hold the error if there is a return value

      # Don't kill the job, they won't get the statistics, but at least
      # users can get their output data
      $self->log('warn', $!);
    } else {
      # Should be a single, unterminated line, valid json
      my $jsonStr = <$jsonFh>;

      $statsHref = decode_json($jsonStr);
    }
  }

  ################ Compress if wanted ##########
  $self->_moveFilesToFinalDestinationAndDeleteTemp();

  return (undef, $statsHref, $self->outputFilesInfo);
}

sub logProgress {
  my $self = shift;

  #my ($total, $progress, $error) = (0, 0, '');
  # my $error = '';
  my $total = 0;

  my $hasPublisher = $self->hasPublisher;

  return sub {
    #my ($progress) = @_;
    ##    $_[0] 

    if(defined $_[0]) {
      if(!$hasPublisher) {
        return;
      }

      $total += $_[0];

      $self->publishProgress($total);
      return;
    }
  }
}

# Accumulates data from the database, and writes an output string
sub annotateLines {
  my ($self, $linesAref, $outFh, $statsFh) = @_;

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

        # Accumulate the output
        $outputString .= $self->{_outputter}->makeOutputString(\@output);

        # $self->{_outputter}->indexOutput(\@output);

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

  # write everything for this part
  # This should come last, makeOutputString may mutate @output
  $outputString .= $self->{_outputter}->makeOutputString(\@output);

  MCE->print($outFh, $outputString );

  if($statsFh) {
    MCE->print($statsFh, $outputString);
  }
  
  # $self->{_outputter}->indexOutput(\@output);
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

    $outAref->[$i]{ $self->{_minorAllelesKey} } = $cached->{$givenRef}{ $inputAref->[$i][$self->{_alleleFieldIdx}] };
 
    ############### Gather all track data (besides reference) #################
    foreach(@{ $self->{_trackGettersExceptReference} }) {
      # Pass: dataFromDatabase, chromosome, position, real reference, alleles
      $outAref->[$i]{$_->name} = $_->get(
        $dataFromDbAref->[$i], $chr, $outAref->[$i]{$self->{_positionKey}}, $outAref->[$i]{$refTrackName},
        $outAref->[$i]{ $self->{_minorAllelesKey} } );
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
        push @{$outAref->[$i]{ $self->{_heterozygoteIdsKey} } }, $id;

        if( index($iupac{$geno}, $inputAref->[$i][$self->{_referenceFieldIdx}] ) == -1 ) {
          push @{ $outAref->[$i]{ $self->{_compoundHetorzygotesIdsKey} } }, $id;
        }
      } elsif( exists $homs{$geno} ) {
        push @{ $outAref->[$i]{ $self->{_homozygoteIdsKey} } }, $id;
      } else {
        $self->log( 'warn', "$geno wasn't homozygous or heterozygous for sample $id" );
      }
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

  # To send a message to clean up files.
  # TODO: Need somethign better
  #MCE->gather(undef, undef, $msg);
  
  $self->log('warn', $msg);
  return $msg;
}

sub _openStatsFh {
  my $self = shift;
  my $statsProg = which($self->statisticsProgramPath);

  my $assembly = $self->assembly;

  my $primaryDelimiter = $self->{_outputter}->delimiters->primaryDelimiter;
  my $secondaryDelimiter = $self->{_outputter}->delimiters->secondaryDelimiter;
  my $fieldSeparator = $self->{_outputter}->delimiters->fieldSeparator;

  my $numberHeaderLines = 1;

  my $refColumnName = $self->{_refTrackGetter}->name;
  my $alleleColumnName = $self->{_minorAllelesKey};
  my $siteTypeColumnName = $self->statistics->{site_type_column_name};

  my $homozygotesColumnName = $self->{_homozygoteIdsKey};
  my $heterozygotesColumnName = $self->{_heterozygoteIdsKey};

  my $jsonOutPath = $self->outputFilesInfo->{statistics}{json};
  my $tabOutPath = $self->outputFilesInfo->{statistics}{tab};
  my $qcOutPath = $self->outputFilesInfo->{statistics}{qc};

  # These two are optional
  my $snpNameColumnName = $self->statistics->{dbSNP_name_column_name} || "";
  my $exonicAlleleFuncColumnName = $self->statistics->{exonic_allele_function_column_name} || "";

  if (! ($refColumnName && $alleleColumnName && $siteTypeColumnName && $homozygotesColumnName
    && $heterozygotesColumnName && $jsonOutPath && $tabOutPath && $qcOutPath && $numberHeaderLines != 1) ) {
    return ("Need, refColumnName, alleleColumnName, siteTypeColumnName, homozygotesColumnName,"
      . "heterozygotesColumnName, jsonOutPath, tabOutPath, qcOutPath, "
      . "primaryDelimiter, secondaryDelimiter, fieldSeparator, and "
      . "numberHeaderLines must equal 1 for statistics", undef);
  }

  if ($statsProg == undef) {
    return ("Couldn't find statistics program at " . $self->statisticsProgramPath)
  }

  my $fh;
  if( open($fh, "|-", "$statsProg -outputJSONPath $jsonOutPath -outputTabPath $tabOutPath "
    . "-outputQcTabPath $qcOutPath -referenceColumnName $refColumnName "
    . "-alleleColumnName $alleleColumnName -homozygotesColumnName $homozygotesColumnName "
    . "-heterozygotesColumnName $heterozygotesColumnName -siteTypeColumnName $siteTypeColumnName "
    . "-dbSNPnameColumnName $snpNameColumnName "
    . "-exonicAlleleFunctionColumnName $exonicAlleleFuncColumnName "
    . "-primaryDelimiter $primaryDelimiter -fieldSeparator $fieldSeparator "
    . "-secondaryDelimiter $secondaryDelimiter -fieldSeparator $fieldSeparator") ) {

    return ($!, $fh);
  }

  return (undef, $fh);
}
__PACKAGE__->meta->make_immutable;

1;
