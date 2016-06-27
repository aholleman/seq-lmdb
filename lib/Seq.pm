use 5.10.0;
use strict;
use warnings;

package Seq;

our $VERSION = '0.001';

# ABSTRACT: Annotate a snp file
# VERSION

=head1 DESCRIPTION

  @class B<Seq>
  Annotate.

  @example

Used in: None

Extended by: None

=cut

use Moose 2;
use MooseX::Types::Path::Tiny qw/AbsFile AbsPath AbsDir/;

use Path::Tiny;
use File::Temp qw/ tempdir /;
use namespace::autoclean;

use DDP;

use MCE::Loop;
use MCE::Shared;

use Seq::InputFile;
use Seq::Output;
use Seq::Headers;

extends 'Seq::Base';

use Seq::Tracks;

with 'Seq::Role::Genotypes';

# use Seq::Progress;

has snpfile => (
  is       => 'ro',
  isa      => AbsFile,
  coerce   => 1,
  required => 1,
  handles  => { snpfile_path => 'stringify' }
);

has out_file => (
  is        => 'ro',
  isa       => AbsPath,
  coerce    => 1,
  required  => 1,
  handles   => { output_path => 'stringify' }
);

# TODO: add this back
# has ignore_unknown_chr => (
#   is      => 'ro',
#   isa     => 'Bool',
#   default => 1,
#   lazy => 1,
# );

#we also add a few of our own annotation attributes
#these will be re-used in the body of the annotation processor below
my $heterozygousIdsKey = 'heterozygotes';
my $compoundIdsKey = 'compoundHeterozygotes';
my $homozygousIdsKey = 'homozygotes';

#knows about the snp file headers
my $inputFileProcessor = Seq::InputFile->new();

#handles creation of our output strings
my $outputter = Seq::Output->new();

#reused in annotation body, need to be set after reading first line
#of input file
#These are filled after the first line of the input is read; before that we
#don't know which file type we have
my $chrFieldIdx;
my $referenceFieldIdx;
my $positionFieldIdx;
my $alleleFieldIdx;
my $typeFieldIdx;

my $chrFieldName;
my $positionFieldName;
my $alleleFieldName;
my $typeFieldName;

my $sampleIDsToIndexesMap;
my $sampleIDaref;

my $refTrackGetter;
my $trackGettersExceptReference;

my $fileSize;
my $chunkSize;
#our only required value: the tracks configuration (typically from YAML)
has tracks => (
  is => 'ro',
  required => 1,
);

sub BUILD {
  my $self = shift;

  my $tracks = Seq::Tracks->new( {tracks => $self->tracks, gettersOnly => 1} );

  # We won't be building anything, optimize locking for read
  $self->dbReadOnly(1);
  #the reference base can be used for many purposes
  #and so to benefit encapsulation, I separate it from other tracks during getting
  #this way, tracks can just accept the first four fields of the input file
  # chr, pos, ref, alleles, using the empirically found ref
  $refTrackGetter = $tracks->getRefTrackGetter();

  #all other tracks
  for my $trackGetter ($tracks->allTrackGetters) {
    if($trackGetter->name ne $refTrackGetter->name) {
      push @$trackGettersExceptReference, $trackGetter;
    }
  }
}

sub annotate_snpfile {
  my $self = shift;

  $self->log( 'info', 'Beginning annotation' );

  # Set the lmdb database to read only, remove locking
  # We MUST make sure everything is written to the database by this point,
  # including any meta fields
  $self->setDbReadOnly(1);

  my $headers = Seq::Headers->new();
  
  my $fh;

  ($fileSize, $fh) = $self->get_read_fh($self->snpfile_path);
    
  my $taint_check_regex = $self->taint_check_regex; 
  my $endOfLineChar = $self->endOfLineChar;
  my $delimiter = $self->delimiter;

  #first line is header
  #strip it from the file, and write it to disk
  my $firstLine = <$fh>;

  chomp $firstLine;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    $firstLine = [ split $delimiter, $1 ];

    $inputFileProcessor->checkInputFileHeader($firstLine);

    #fill after checking input headers, because before then we don't know
    #what kind of file we're reading
    $chrFieldIdx = $inputFileProcessor->chrFieldIdx;
    $referenceFieldIdx = $inputFileProcessor->referenceFieldIdx;
    $positionFieldIdx = $inputFileProcessor->positionFieldIdx;
    $alleleFieldIdx = $inputFileProcessor->alleleFieldIdx;
    $typeFieldIdx = $inputFileProcessor->typeFieldIdx;

    $chrFieldName = $inputFileProcessor->chrFieldName;
    $positionFieldName = $inputFileProcessor->positionFieldName;
    $alleleFieldName = $inputFileProcessor->alleleFieldName;
    $typeFieldName = $inputFileProcessor->typeFieldName;

    #1 means prepend
    $headers->addFeaturesToHeader( [$chrFieldName, $positionFieldName, $alleleFieldName,
      $typeFieldName, $heterozygousIdsKey, $homozygousIdsKey, $compoundIdsKey ], undef, 1);

    #outputter needs to know which fields we're going to want to writer
    $outputter->setOutputDataFieldsWanted( $headers->get() );

    $sampleIDsToIndexesMap = { $inputFileProcessor->getSampleNamesIdx( $firstLine ) };

    # save list of ids within the snpfile
    $sampleIDaref =  [ sort keys %$sampleIDsToIndexesMap ];

  } else {
    $self->log('fatal', "First line of input file has illegal characters");
  }

  my $outFh = $self->get_write_fh( $self->output_path );
  
  #write header to file
  say $outFh $headers->getString();

  #initialize our parallel engine; re-uses forks
  my $a = MCE::Loop::init {
    #slurpio is optimized with auto chunk
    chunk_size => 'auto',
    max_workers => 64,
    use_slurpio => 1,
    gather => $self->logMessages(),
    #doesn't seem to improve performance
    #and apparently slow on shared storage
    # parallel_io => 1,
  };

  # To avoid this ugliness could use MCE::Loop core api
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

    while (<$MEM_FH>) {
    if (/$taint_check_regex/) {
      chomp;
      my $line = [ split $delimiter, $_ ];

      if ( !$refTrackGetter->chrIsWanted($line->[0] ) ) {
        next;
      }
      #check conditions separately, becaues faster
      if($line->[$typeFieldIdx] =~ "LOW" || $line->[$typeFieldIdx] =~ "MESS") {
        next;
      }

      push @lines, $line;
    }
    }
    close  $MEM_FH;

    #write to file
    $self->annotateLines(\@lines, $outFh);
    MCE->gather(1);
    #MCE->print($outFh, $self->annotateLines(\@lines) );
  } $fh;
}

sub logMessages {
  my $self = shift;
  my $total = 0;
  my $progress = 0;
  state $hasPublisher = $self->hasPublisher;

  return sub {
    if($hasPublisher) {
      $total += $chunkSize;
      # Can exceed total because last chunk may be over-stated in size
      if($total > $fileSize) {
        $progress = 1;
      } else {
        $progress = sprintf '%0.2f', $total / $fileSize;
      }

      $self->publishProgress($progress);
    }

    ## Handle statistics accumulation
  }
}

#Accumulates data from the database, then returns an output string
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
        
        # and prepare those reults for output, save the accumulated string value
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

  #write everything for this part
  MCE->print($outFh, $outputString . $outputter->makeOutputString(\@output) );

  #TODO: need also to take care of statistics stuff
}

#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub finishAnnotatingLines {
  my ($self, $chr, $dataFromDbAref, $inputAref, $positionsAref, $outAref) = @_;

  state $refTrackName = $refTrackGetter->name;
  state $cached;
  #note, that if dataFromDbRef, and inputAref contain different numbers
  #of records, that is evidence of a programmatic bug
  for (my $i = 0; $i < @$inputAref; $i++) {
    if(!defined $dataFromDbAref->[$i] ) {
      $self->log('fatal', "$chr: " . $inputAref->[$i][1] . " not found.
        You may have chosen the wrong assembly.");
    }

    $outAref->[$i]{$refTrackName} = $refTrackGetter->get($dataFromDbAref->[$i]);

    my $givenRef = $inputAref->[$i][$referenceFieldIdx];

    #TODO: figure out if we should actually output a line for this case
    if( $outAref->[$i]{$refTrackName} eq 'N') {
      $self->log('warn', "Reference is 'N' in this assembly. You may have chosen the wrong assembly.");
      next;
    }

    if( $outAref->[$i]{$refTrackName} ne $givenRef) {
      $self->log('warn', "Reference discordant @ $inputAref->[$i][$chrFieldIdx]\:$inputAref->[$i][$positionFieldIdx]");
    }

    ############### Gather genotypes ... cache to avoid re-work ###############
    #$cached->{genotype}->{$reference} = $minorAllele
    my $allelesAref;
    
    if(defined $cached->{$givenRef}->{ $inputAref->[$i][$alleleFieldIdx] } ) {
      $allelesAref = $cached->{$givenRef} ->{ $inputAref->[$i][$alleleFieldIdx] };
    } else {
      for my $allele ( split(',', $inputAref->[$i][$alleleFieldIdx] ) ) {
        if($allele ne $givenRef) {
          push @$allelesAref, $allele;
        }
      }

      if(@$allelesAref == 1) {
        $allelesAref = $allelesAref->[0];
      }

      $cached->{$givenRef} ->{ $inputAref->[$i][$alleleFieldIdx] } = $allelesAref;
    }

    ############### Gather all track data (besides reference) #################

    #Note: the output order does not matter for any single $i
    #Ordering is handled by Output.pm

    #some tracks may also want the alternative alleles, so give those as last arg
    #example: cadd track needs this
    foreach(@$trackGettersExceptReference) {
      #we pass: dataFromDatabase, chromosome, position, real reference, alleles
      $outAref->[$i]->{$_->name} = $_->get($dataFromDbAref->[$i], $chr, 
        $positionsAref->[$i], $outAref->[$i]{$refTrackName}, $allelesAref) 
    };

    ############# Store chr, position, alleles, type ###############

    $outAref->[$i]{$chrFieldName} = $inputAref->[$i][$chrFieldIdx];
    $outAref->[$i]{$positionFieldName} = $inputAref->[$i][$positionFieldIdx];
    $outAref->[$i]{$alleleFieldName} = $inputAref->[$i][$alleleFieldIdx];
    $outAref->[$i]{$typeFieldName} = $inputAref->[$i][$typeFieldIdx];

    ############ Store homozygotes, heterozygotes, compoundHeterozygotes ########
    SAMPLE_LOOP: for my $id ( @$sampleIDaref ) {
      my $geno = $inputAref->[$i][ $sampleIDsToIndexesMap->{$id} ];

      if( $geno eq 'N' || $geno eq $givenRef ) {
        next SAMPLE_LOOP;
      }

      if ( $self->isHet($geno) ) {
        $outAref->[$i]{$heterozygousIdsKey} .= "$id;";

        if( $self->isCompoundHeterozygote($geno, $inputAref->[$i][$referenceFieldIdx] ) ) {
          $outAref->[$i]{$compoundIdsKey} .= "$id;";
        }
      } elsif( $self->isHomo($geno) ){
        $outAref->[$i]{$homozygousIdsKey} .= "$id;";
      } else {
        $self->log( 'warn', "$geno wasn't homozygous or heterozygous" );
      }

      #statistics calculator wants the actual genotype
      #but we're not using this for now
      #$sampleIDtypes[3]->{$id} = $geno;
    }

    if   ($outAref->[$i]{$homozygousIdsKey}) { chop $outAref->[$i]{$homozygousIdsKey}; }
    if   ($outAref->[$i]{$heterozygousIdsKey}) { chop $outAref->[$i]{$heterozygousIdsKey}; }
    if   ($outAref->[$i]{$compoundIdsKey}) { chop $outAref->[$i]{$compoundIdsKey}; }
  }

  return $outAref;
}

__PACKAGE__->meta->make_immutable;

1;
