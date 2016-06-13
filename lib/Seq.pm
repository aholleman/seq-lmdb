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

use Seq::InputFile;
use Seq::Output;
use Seq::Headers;

extends 'Seq::Tracks';

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

sub BUILD {
  my $self = shift;

  #the reference base can be used for many purposes
  #and so to benefit encapsulation, I separate it from other tracks during getting
  #this way, tracks can just accept the first four fields of the input file
  # chr, pos, ref, alleles, using the empirically found ref
  $refTrackGetter = $self->singletonTracks->getRefTrackGetter();

  #all other tracks
  for my $trackGetter ($self->singletonTracks->allTrackGetters) {
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
  
  my $fh = $self->get_read_fh($self->snpfile_path);
  
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
  MCE::Loop::init {
    #slurpio is optimized with auto chunk
    chunk_size => 'auto',
    max_workers => 32,
    use_slurpio => 1,
    #doesn't seem to improve performance
    #and apparently slow on shared storage
    # parallel_io => 1,
  };

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    # Quickly determine if a match is found.
    # Process the slurped chunk only if true.

     my @lines;

     # http://search.cpan.org/~marioroy/MCE-1.706/lib/MCE.pod
     # The following is fast on Unix, but performance degrades
     # drastically on Windows beyond 4 workers.

     open my $MEM_FH, '<', $slurp_ref;
     binmode $MEM_FH, ':raw';

     while (<$MEM_FH>) {
      if (/$taint_check_regex/) {
        chomp;
        my $line = [ split $delimiter, $_ ];
        if($line->[$typeFieldIdx] =~ /MESS|LOW/) {
          next;
        }

        push @lines, $line;
      }
     }
     close  $MEM_FH;

    #write to file
    $self->annotateLines(\@lines, $outFh);
   #MCE->print($outFh, $self->annotateLines(\@lines) );
  } $fh;
}

#TODO: Need to implement unknown chr check, LOW/MESS check
#TODO: return # of discordant bases from children if wanted

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
  my ($self, $chr, $databaseAref, $inputAref, $positionsAref, $outAref) = @_;

  state $refTrackName = $refTrackGetter->name;
  state $cached;
  #note, that if dataFromDbRef, and inputAref contain different numbers
  #of records, that is evidence of a programmatic bug
  for (my $i = 0; $i < @$inputAref; $i++) {
    if(!defined $databaseAref->[$i] ) {
      $self->log('fatal', "$chr: " . $inputAref->[$i][1] . " not found.
        You may have chosen the wrong assembly.");
    }

    $outAref->[$i]{$refTrackName} = $refTrackGetter->get($databaseAref->[$i]);

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
      $outAref->[$i]->{$_->name} = $_->get($databaseAref->[$i], $chr, 
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

    #Could check for discordant bases here
    
    #Annotate the Indel, which is a bit like annotating a bunch of other
    #sites
    #and is held in a separate package, Sites::Indels
    #it takes the chr, and the current site's annotation data
    #then it will fetch the required sites, and get the gene track
    #TODO: finish implementing
    #$self->annotateIndel( $chr, \%singleLineOutput, $inputAref->[$i] );

    #Indels
  }

  return $outAref;
}

__PACKAGE__->meta->make_immutable;

1;

#TODO: Figure out what to do with messaging progress
  #if (!$pubProg && $self->hasPublisher) {
    # $pubProg = Seq::Progress->new({
    #   progressBatch => 200,
    #   fileLines => scalar @$fileLines,
    #   progressAction => sub {
    #     $pubProg->recordProgress($pubProg->progressCounter);
    #     $self->publishMessage({progress => $pubProg->progressFraction } )
    #   },
    # });
  #}
  
  #if(!$writeProg) {
    # $writeProg = Seq::Progress->new({
    #   progressBatch => $self->write_batch,
    #   progressAction => sub {
    #     $self->publishMessage('Writing ' . 
    #       $self->write_batch . ' lines to disk') if $self->hasPublisher;
    #     $self->print_annotations( \@snp_annotations );
    #     @snp_annotations = ();
    #   },
    # });
 # }