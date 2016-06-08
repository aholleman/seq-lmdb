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

use Seq::Tracks::Gene::Site;

with 'Seq::Role::DBManager';

state $indelTypeMap = {
  '-' => 'Deletion',
  '+' => 'Insertion',
};

state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };

state $silent = 'Silent';
state $replacement = 'Replacement';
#TODO: could get this from Gene track, or some other source
#this name is also used in Seq::Tracks::Gene
state $intergenic = 'Intergenic';

state $frameshift = 'Frameshift';
state $inFrame = 'InFrame';
state $startLoss = 'StartLoss';
state $stopLoss = 'StopLoss';

state $truncated = 'Error_truncated';

state $siteUnpacker;

sub BUILD {
  $siteUnpacker = Seq::Tracks::Gene::Site->new();
}

#@param <String|ArrayRef? $allelesAref : this site's alleles
sub get {
  #my ($self, $siteData, $chr, $refBase, $dbPosition, $allelesAref) = @_;
  
  #$_[4] == $alllelesAref
  if(defined $indelTypeMap->{$_[4]} ) {
    if( $indelTypeMap->{$_[4]} eq 'Insertion' ) {
      goto &_annotateInsertion;
    }
    goto &_annotateDeletion;
  }

  if(! ref $_[4] ) {
    goto &_annotateSnp;
  }

  ############### Annotate multi-allelic sites ################
  my $multialleleOut = '';

  for my $allele ( @{$_[4]} ) {
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
  my ($self, $siteDataAref, $chr, $refBase, $dbPosition, $allele) = @_;
  
  my $out = '';

  for my $siteData (@$siteDataAref) {
    my $siteCodon = $siteData->{ $siteUnpacker->codonSequenceKey };
    
    #if there is no codon sequence, just use
    if(!$siteCodon) {
      $out .= $siteData->{ $siteUnpacker->siteTypeKey } . ";";
      next;
    }

    if(length($siteCodon) != 3) {
      $self->log('warn', "A codon @ $chr: @{[$dbPosition + 1]} is not 3 bases long" .
        " Got @{[length($siteCodon)]} instead");
      $out .= "$truncated;";
      next;
    }

    my $refCodon = $siteCodon;

    if( $siteData->{ $siteUnpacker->strandKey } ) {
      $refBase = $negativeStrandTranslation->{$refBase};
    }

    substr($refCodon, $siteData->{ $siteUnpacker->codonPositionKey }, 1 ) = $refBase;

    if( $siteUnpacker->codonMap->codon2aa($siteCodon) eq $siteUnpacker->codonMap->codon2aa($refCodon) ) {
      $out .= "$silent;";
    }

    $out .= "$replacement;";
  }

  chop $out;
  return;
}

# @param <Seq::Site::Tracks::Gene> $geneTrack : an instance of the gene track
# that we want to use to annotate this insertion
# allows use of more than 1 gene track
sub _annotateInsertion {
  my ($self, $siteDataAref, $chr, $dbPosition,, $refBase, $allele, $geneTrack) = @_;

  my $out = (length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame) ."[";

  my $nextData = $self->dbRead( $dbPosition + 1);

  if (! defined $nextData->{ $geneTrack->dbName } ) {
    say "nextData doesn't have geneTrack, result is : '$out$intergenic];'";
    return "$out$intergenic];";
  }

  my $nextSiteDataRef = $nextData->{ $geneTrack->dbName }->{ 
    $geneTrack->getFieldDbName( $geneTrack->siteFeatureName ) };

  if(!ref $nextSiteDataRef) {
    $nextSiteDataRef = [$nextSiteDataRef];
  }

  for my $nextSiteData (@$nextSiteDataRef) {
    if ( $nextSiteData->{ $siteUnpacker->codonNumberKey } == 1 ) {
      $out .= "$startLoss;";
    } elsif ( $nextSiteData->{ $siteUnpacker->peptideKey } eq '*' ) {
      $out .= "$stopLoss;";
    } else {
      $out .= $nextSiteData->{ $siteUnpacker->siteTypeKey } . ";";
    }
  }
  chop $out;

  say "nextData does have geneTrack, result is : '$out;'";
  return "$out]";
}

sub _annotateDeletion {
  my ($self, $siteDataAref, $chr, $dbPosition, $refBase, $allele, $geneTrack) = @_;

  #https://ideone.com/ydQtgU
  my $frameLabel = $allele % 3 ? $frameshift : $inFrame;

  my $nextDataAref = $self->dbRead( $dbPosition + $allele);

  my $out = ($allele % 3 ? $frameshift : $inFrame) . "[";

  my $count = 0;
  my $lastSiteDataRef;
  for my $nextData (@$nextDataAref) {
    $count++;

    if (! defined $nextData->{ $geneTrack->dbName } ) {
      $out .= "$intergenic;";

      if ($count == @$nextDataAref) {
        $lastSiteDataRef = $siteDataAref;
      } else {
        next;
      }
    }
    
    my $nextSiteDataRef = $nextData->{ $geneTrack->dbName }->{ 
      $geneTrack->getFieldDbName( $geneTrack->siteFeatureName ) };

    if(! ref $nextSiteDataRef ) {
      $nextSiteDataRef = [$nextSiteDataRef];
    }

    if ($lastSiteDataRef) {
      push @$nextSiteDataRef, $lastSiteDataRef;
    }

    say "nextSiteDataRef is";
    p $nextSiteDataRef;

    for my $nextSiteData (@$nextSiteDataRef) {
      if ( $nextSiteData->{ $siteUnpacker->codonNumberKey } == 1 ) {
        $out .= "$startLoss;";
      } elsif ( $nextSiteData->{ $siteUnpacker->peptideKey } eq '*' ) {
        $out .= "$stopLoss;";
      } else {
        $out .= $nextSiteData->{ $siteUnpacker->siteTypeKey } . ";";
      }
    }
  }

  chop $out;
  say "deletion transcript effects are : '$out;'";
  return "$out]";
}

__PACKAGE__->meta->make_immutable;

1;
