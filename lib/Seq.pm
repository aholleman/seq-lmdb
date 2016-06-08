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

# TODO: add
# The reference track is used to check on discordant bases
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
    $headers->addFeaturesToHeader( [
      $inputFileProcessor->chrFieldName, $inputFileProcessor->positionFieldName,
      $inputFileProcessor->alleleFieldName, $inputFileProcessor->typeFieldName,
      $heterozygousIdsKey, $homozygousIdsKey, $compoundIdsKey ], undef, 1);

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
    gather => sub {
      #say "gathering";
      open (my $fh, '>>', $self->output_path);
      print $fh $_[0];
    },
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
    $self->annotateLines(\@lines);
  } $fh;
}

#TODO: Need to implement unknown chr check, LOW/MESS check
#TODO: return # of discordant bases from children if wanted

#Accumulates data from the database, then returns an output string
sub annotateLines {
  my ($self, $linesAref, $outFh) = @_;

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
        MCE->gather( $outputter->makeOutputString( $self->finishAnnotatingLines($wantedChr,
          $dataFromDatabaseAref, \@inputData, \@positions) ) );

        #erase accumulated values; relies on finishAnnotatingLines being synchronous
        #this will let us repeat the finishAnnotatingLines process
        undef @positions;
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

    MCE->gather( $outputter->makeOutputString( $self->finishAnnotatingLines($wantedChr, 
      $dataFromDatabaseAref, \@inputData, \@positions) ) );
  }

  #write everything for this part
  return $outputString;

  #TODO: need also to take care of statistics stuff
}

#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub finishAnnotatingLines {
  my ($self, $chr, $databaseDataAref, $inputDataAref) = @_;

  state $refTrackName = $refTrackGetter->name;

  my @output;
  ########### Iterate over all records, and build up the $outAref ##############
  #note, that if dataFromDbRef, and inputDataAref contain different numbers
  #of records, that is evidence of a programmatic bug
  for (my $i = 0; $i < @$inputDataAref; $i++) {
    if(!defined $databaseDataAref->[$i] ) {
      $self->log('fatal', "$chr: " . $inputDataAref->[$i][1] . " not found.
        You may have chosen the wrong assembly.");
    }

    $output[$i] = {
      $refTrackName => $refTrackGetter->get($databaseDataAref->[$i])
    };
    ###### Get the true reference, and check whether it matches the input file reference ######
    #$outAref->[$i]{$refTrackName} = $refTrackGetter->get($databaseDataAref->[$i]);

    if( $output[$i]{$refTrackName} ne $inputDataAref->[$i][$referenceFieldIdx] ) {
      $self->log('warn', "Input file reference doesn't match our reference, ".
        "at $inputDataAref->[$i][$chrFieldIdx]\:$inputDataAref->[$i][$positionFieldIdx]");
    }

    ################ Gather all alleles ################################
    #uses the reference found in the snp file, rather than true reference
    #because it's not clear what to do in the discordant case
    #and so we want to pass the most conservative list of variants to trackGetters that need them
    my $allelesAref;
    for my $allele ( split(',', $inputDataAref->[$i][$alleleFieldIdx] ) ) {
      if($allele ne $inputDataAref->[$i][$referenceFieldIdx]) {
        push @$allelesAref, $allele;
      }
    }

    if(@$allelesAref == 1) {
      $allelesAref = $allelesAref->[0];
    }

    ####################### Collect all Track data #####################
    #Note: the key order does not matter within any $outAref->[$i]
    #Ordering is handled by Output.pm

    #We pass chr, position, ref (true reference from our assembly), and alleles
    #in the order found in any snp file. These are the only input fields expected
    #by our track getters
    #the database data is always the first
    push @output, { map {
      $_->name => $_->get( $databaseDataAref->[$i], $inputDataAref->[$i][$chrFieldIdx],
        $inputDataAref->[$i][$positionFieldIdx], $output[$i]{$refTrackName}, $allelesAref )
    } @$trackGettersExceptReference };

    ################ Store chr, position, alleles, type ##################
    $output[$i]{$chrFieldName} = $inputDataAref->[$i][$chrFieldIdx];
    $output[$i]{$positionFieldName} = $inputDataAref->[$i][$positionFieldIdx];
    $output[$i]{$alleleFieldName} = $inputDataAref->[$i][$alleleFieldIdx];
    $output[$i]{$typeFieldName} = $inputDataAref->[$i][$typeFieldIdx];

    ########### Store homozygotes, heterozygotes, compoundHeterozygotes #########
    SAMPLE_LOOP: for my $id ( @$sampleIDaref ) { # same as for my $id (@$id_names_aref);
      my $geno = $inputDataAref->[$i][ $sampleIDsToIndexesMap->{$id} ];

      # Check whether the genotype is undefined or reference
      # Uses the input-file provided reference, because not clear what to do in discordant case
      if( $geno eq 'N' || $geno eq $inputDataAref->[$i][$referenceFieldIdx] ) {
        next SAMPLE_LOOP;
      }

      if ( $self->isHet($geno) ) {
        $output[$i]{$heterozygousIdsKey} .= "$id;";

        if( $self->isCompoundHeterozygote($geno, $inputDataAref->[$i][$referenceFieldIdx] ) ) {
          $output[$i]{$compoundIdsKey} .= "$id;";
        }
      } elsif( $self->isHomo($geno) ){
        $output[$i]{$homozygousIdsKey} .= "$id;";
      } else {
        $self->log( 'warn', "$geno wasn't homozygous or heterozygous" );
      }
    }

    if   ($output[$i]{$homozygousIdsKey}) { chop $output[$i]{$homozygousIdsKey}; }
    if   ($output[$i]{$heterozygousIdsKey}) { chop $output[$i]{$heterozygousIdsKey}; }
    if   ($output[$i]{$compoundIdsKey}) { chop $output[$i]{$compoundIdsKey}; }
  }

  return \@output;
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
