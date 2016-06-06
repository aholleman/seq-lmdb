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

extends 'Seq::Base';

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
my $chrFieldIdx;
my $referenceFieldIdx;
my $positionFieldIdx;
my $alleleFieldIdx;
my $typeFieldIdx;

sub annotate_snpfile {
  my $self = shift;

  $self->log( 'info', 'Beginning annotation' );

  my $headers = Seq::Headers->new();
  
  my $fh = $self->get_read_fh($self->snpfile_path);
  
  my $sampleIDsToIndexesMap;
  my $taint_check_regex = $self->taint_check_regex; 
  my $endOfLineChar = $self->endOfLineChar;
  my $delimiter = $self->delimiter;

  my $sampleIDaref;
    
  #first line is header
  #strip it from the file, and write it to disk
  my $firstLine = <$fh>;

  chomp $firstLine;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    $firstLine = [ split $delimiter, $1 ];

    $inputFileProcessor->checkInputFileHeader($firstLine);

    $chrFieldIdx = $inputFileProcessor->chrFieldIdx;
    $referenceFieldIdx = $inputFileProcessor->chrFieldIdx;
    $positionFieldIdx = $inputFileProcessor->positionFieldIdx;
    $alleleFieldIdx = $inputFileProcessor->alleleFieldIdx;
    $typeFieldIdx = $inputFileProcessor->typeFieldIdx;

    #should match the header order
    $outputter->setInputFieldsWantedInOutput(
      [ $chrFieldIdx, $positionFieldIdx, $alleleFieldIdx, $typeFieldIdx ]
    );

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

    # http://www.perlmonks.org/?node_id=1110235
    # MCE->gather($chunk_id, $self->annotateLines($_, $sampleIDsToIndexesMap, $sampleIDaref, $chunk_id));
    MCE->say($outFh, $self->annotateLines(\@lines, $sampleIDsToIndexesMap, $sampleIDaref) );
  } $fh;
}

#TODO: Need to implement unknown chr check, LOW/MESS check
#TODO: return # of discordant bases from children if wanted

#after we've accumulated lines, process them
sub annotateLines {
  #$pm->start and return;
  my ($self, $linesAref, $idsIdxMapHref, $sampleIdsAref) = @_;

  my @output;

  my $wantedChr;
  my @inputData;
  my @positions;
  my @sampleData;
  my ( $chr, $pos, $refAllele, $varType, $allAllelesStr );
  my @fields;

  # say "snp field indices are";
  # p $inputFileProcessor->snpFieldIndices;
  # exit;
  state $firstSnpFieldIndex = $inputFileProcessor->snpFieldIndices->[0];
  state $lastSnpFieldIndex = $inputFileProcessor->snpFieldIndices->[-1];

  #Note: Expects first 3 fields to be chr, position, reference
  for my $fieldsAref (@$linesAref) {
    #maps to
    #my ( $chr, $pos, $referenceAllele, $variantType, $allAllelesStr ) =
    
    my @snpFields = @$fieldsAref[ $firstSnpFieldIndex .. $lastSnpFieldIndex ];
    
    if( $snpFields[$referenceFieldIdx] eq $snpFields[$alleleFieldIdx] ) {
      next;
    }

    push @inputData, \@snpFields;

    #$snpFields[0] expected to be chr
    if($wantedChr && $snpFields[0] ne $wantedChr) {
      #don't sort to preserve order 
      my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions, 1); 

      $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
        \@sampleData, \@positions, \@output);
      @positions = ();
      @inputData = ();
      @sampleData = ();
    }

    $wantedChr = $snpFields[$chrFieldIdx];
    
    # get carrier ids for variant; returns hom_ids_href for use in statistics calculator

    #$ref_allele == $snpFields[2]
    my $sampleIDtypesAref; 
    for my $id ( @$sampleIdsAref ) { # same as for my $id (@$id_names_aref);
      my $geno = $fieldsAref->[ $idsIdxMapHref->{$id} ];

      if( $geno eq 'N' || $geno eq $snpFields[$referenceFieldIdx] ) {
        next;
      }

      if ( $self->isHet($geno) ) {
        $sampleIDtypesAref->[0] .= "$id;";

        if( $self->isCompoundHeterozygote($geno, $snpFields[2] ) ) {
          $sampleIDtypesAref->[2] .= "$id;";
        }
      } elsif( $self->isHomo($geno) ){
        $sampleIDtypesAref->[1] .= "$id;";
      } else {
        $self->log( 'fatal', "$geno wasn't homozygous or heterozygous" );
      }
       $sampleIDtypesAref->[3]{$id} = $geno;
    }
    if   ($sampleIDtypesAref->[0]) { chop $sampleIDtypesAref->[0]; }
    if   ($sampleIDtypesAref->[1]) { chop $sampleIDtypesAref->[1]; }
    if   ($sampleIDtypesAref->[2]) { chop $sampleIDtypesAref->[2]; }

    push @sampleData, $sampleIDtypesAref;
    # if perf identical, could use: 
    # @sampleIDargs == same as my ( $hetIds, $homIds, $compoundsHetIds, $sampleIDtoGenotypeMap ) =
    # push @sampleData, [ $self->_minor_allele_carriers( \@fields, $idsIdxMapHref, 
    #     $sampleIdsAref, $snpFields[2] ) ];

    #$snpFields[1] expected to be the relative position
    #we store everything 0-indexed, so substract 1
    push @positions, $snpFields[$positionFieldIdx] - 1;

  }

  #finish anything left over
  if(@positions) {
    my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions, 1); 

    $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
      \@sampleData, \@positions, \@output);
  }

  #write everything for this part
  return $outputter->makeOutputString(\@output, \@inputData);

  #TODO: need also to take care of statistics stuff
}

#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub finishAnnotatingLines {
  my ($self, $chr, $dataFromDbRef, $dataFromInputAref, $sampleGenotypesAref, 
    $positionsAref, $outAref) = @_;

  my $dataFromDbAref = ref $dataFromDbRef eq 'ARRAY' ? $dataFromDbRef : [$dataFromDbRef];

  my @trackGetters = $self->getAllTrackGetters();
  #@$dataFromDBaRef == @$dataFromInputAref
  for (my $i = 0; $i < @$dataFromInputAref; $i++) {
    if(!defined $dataFromDbAref->[$i] ) {
      $self->log('fatal', "$chr: " . $dataFromInputAref->[$i][1] . " not found.
        You may have chosen the wrong assembly");
    }

    my @alleles;
    for my $allele ( split(',', $dataFromInputAref->[$i][$alleleFieldIdx] ) ) {
      if($allele ne $dataFromInputAref->[$i][$referenceFieldIdx]) {
        push @alleles, $allele
      }
    }

    #some tracks may also want the alternative alleles, so give those as last arg
    #example: cadd track needs this
    push @$outAref, { map { 
      $_->name => $_->get( 
        $dataFromDbAref->[$i], $chr, \@alleles, $positionsAref->[$i] ) 
    } @trackGetters };

    #$sampleGenotypesAref expected to be ( $het_ids_str, $hom_ids_str, $compounds_ids_str, \%id_genos_href );
    $outAref->[$i]{$heterozygousIdsKey} = $sampleGenotypesAref->[$i][0];
    $outAref->[$i]{$homozygousIdsKey} = $sampleGenotypesAref->[$i][1];
    $outAref->[$i]{$compoundIdsKey} = $sampleGenotypesAref->[$i][2];

    #Could check for discordant bases here
    
    #Annotate the Indel, which is a bit like annotating a bunch of other
    #sites
    #and is held in a separate package, Sites::Indels
    #it takes the chr, and the current site's annotation data
    #then it will fetch the required sites, and get the gene track
    #TODO: finish implementing
    #$self->annotateIndel( $chr, \%singleLineOutput, $dataFromInputAref->[$i] );

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
