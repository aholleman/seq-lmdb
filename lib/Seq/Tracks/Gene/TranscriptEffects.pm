use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::TranscriptEffects;

our $VERSION = '0.001';

# ABSTRACT: Given a site, figure out what the site effects
  # (this depends on the allele, and where in the genome it strikes)
# VERSION

use Moose;
use DDP;
use Scalar::Util qw/looks_like_number/;

use Seq::Tracks::SingletonTracks;
use Seq::Tracks::Gene::Site;

with 'Seq::Role::DBManager';

state $indelTypeMap = {
  '-' => 'Deletion',
  '+' => 'Insertion',
};

state $negativeStrandTranslation = ( A => 'T', C => 'G', G => 'C', T => 'A' );

state $silent = 'Silent';
state $replacement = 'Replacement';
#TODO: could get this from Gene track, or some other source
#this name is also used in Seq::Tracks::Gene
state $nonCoding = 'Intergenic';

state $frameshif = 'Frameshift';
state $inFrame = 'InFrame';
state $startLoss = 'StartLoss';
state $stopLoss = 'StopLoss';

state $siteUnpacker;
state $refTrack;

sub BUILD {
  $siteUnpacker = Seq::Tracks::Gene::Site->new();
  if(!$refTrack) {
    my $tracks = Seq::Tracks::SingletonTracks->new();
    
    $refTrack = $singleTracks->getRefTrackGetter();
  }
}

#@param <String|ArrayRef? $allelesAref : this site's alleles
sub get {
  #my ($self, $siteData, $chr, $refBase, $dbPosition, $allelesAref) = @_;

  #$_[4] == $alllelesAref
  if(defined $indelTypeMap->{$_[4]} ) {
    goto &_annotateIndel;
  }

  if(! ref $_[4] ) {
    goto &_annotateSnp;
  }

  my $multialleleOut = '';

  for my $allele ( @{$_[4] } } ) {
    if( defined $indelTypeMap->{$allele} ) {
      if( $indelTypeMap->{$allele} eq 'Insertion' ) {
        $multialleleOut .= $_[0]->_annotateInsertion($_[1], $_[2], $_[3], $allele) . ',';
        
        next;
      }
      $multialleleOut .= $_[0]->_annotateDeletion($_[1], $_[2], $_[3], $allele) . ',';
      
      next;
    }

    $multialleleOut .= $_[0]->_annotateSnp($_[1], $_[2], $_[3], $allele) . ',';
  }

  chop $multialleleOut;

  return $multialleleOut;
}

#@param <HashRef> $siteData : an unpacked codon from <Seq::Gene::Tracks::Site> 
sub _annotateSnp {
  my ($self, $siteData, $chr, $refBase, $dbPosition, $allele) = @_;
  
  my $siteCodon = $siteData->{ siteUnpacker->codonSequenceKey };
  
  if(!$siteCodon) {
    return $nonCoding;
  }

  if(length($siteCodon) != 3) {
    $self->log('warn', "Codon @ $chr: @{[$dbPosition + 1]} is not 3 bases long" .
      " Got @{[length($siteCodon)]} instead");
    return;
  }

  my $refCodon = $siteCodon;

  if( $siteData->{ $siteUnpacker->strandKey } ) {
    $refBase = $negativeStrandTranslation->{$refBase};
  }

  substr($refSequence, $siteData->{ $siteUnpacker->codonPositionKey }, 1 ) = $refBase

  if( $siteUnpacker->codonMap->codon2aa($siteCodon) eq $siteUnpacker->codonMap->codon2aa($refCodon) ) {
    return $silent;
  }

  return $replacement;
}

# @param <Seq::Site::Tracks::Gene> $geneTrack : an instance of the gene track
# that we want to use to annotate this insertion
# allows use of more than 1 gene track
sub _annotateInsertion {
  my ($self, $siteDataAref, $chr, $dbPosition,, $refBase, $allele, $geneTrack) = @_;

  my $length = length( substr($allele, 1) );

  my $frameLabel = length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame;

  my $nextData = $self->dbRead( $dbPosition + 1);

  if(!ref $nextData) {
    $nextData = [$nextData];
  }

  #place the siteData entries before nextData entries
  unshift $nextData, $siteDataAref;

  my $out = "$frameLabel[";

  for my $data (@$nextData) {

  }

  if (! defined $nextData->{ $geneTrack->dbName } ) {
    return "$frameLabel[$nonCoding]"
  }

  my $nextSiteData = $nextData->{ $geneTrack->dbName }->{ 
    $geneTrack->getFieldDbName( $geneTrack->siteFeatureName ) };

  if( $nextSiteData->{ $siteUnpacker->codonNumberKey } == 1 ) {
    return "$frameLabel[$startLoss]";
  }

  if( $nextSiteData->{ $siteUnpacker->peptideKey } eq '*' ) {
    return "$frameLabel[$stopLoss]";
  }

  return "$frameLabel[" . $nextSiteData->{ $siteUnpacker->siteType } . "]";
}

sub _annotateDeletion {
  my ($self, $siteData, $chr, $dbPosition, $refBase, $allele, $geneTrack) = @_;

  my $length = abs($allele);

  my $frameLabel = length % 3 ? $frameshift : $inFrame;

  my $out = $frameLabel . "[";

  my $nextDataAref = $self->dbRead( $dbPosition - ($length - 1) );

  my @siteDataAref;

  for my $data ($nextDataAref) {

  }

  for my $nextData (@$nextDataAref) {
    if (! defined $nextData->{ $geneTrack->dbName } ) {
      $out .= "$nonCoding;";
    }

    my $nextSiteData = $nextData->{ $geneTrack->dbName }->{ 
      $geneTrack->getFieldDbName( $geneTrack->siteFeatureName ) };

    
  }

  chop $out;

  return "$out]";
}

sub _addIndelAnnotationsBulk {
  #$siteData = $_[0]

  my $out;
  for my $data ( $_[0] ) {
    if( ref $data eq 'ARRAY' ) {
      $out .= _addAnnotationsBulk( $data ) . ';';
    }

    if( $_[0]->{ $siteUnpacker->codonNumberKey } == 1 ) {
      $out .= "$startLoss;";
    } elsif( $_[0]->{ $siteUnpacker->peptideKey } eq '*' ) {
      $out .= "$stopLoss;";
    } else {
      $out .= $_[0]->{ $siteUnpacker->siteType } . ';';
    }
  }
  
  chop $out;

  return $out;
}

__PACKAGE__->meta->make_immutable;

1;
