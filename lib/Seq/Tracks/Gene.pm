use 5.10.0;
use strict;
use warnings;
package Seq::Tracks::Gene;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class B<Seq::Gene>
  
  Note: unlike previous SeqAnt, there is no longer a genomic_type
  Just a siteType, which is Intronic, Coding, 5UTR, etc
  This is just like Annovar's
  We add "Intergenic" if not covered by any gene

  This class also handles intergenic sites

=cut

## TODO: remove the if(nearestGeneNumber) check. Right now needed because
## we have no chrM refSeq stuff
use Mouse 2;

use namespace::autoclean;
use DDP;

extends 'Seq::Tracks::Get';
with 'Seq::Tracks::Region::RegionTrackPath';

use Seq::Tracks::Gene::Site;
use Seq::Tracks::Gene::Site::SiteTypeMap;
use Seq::Tracks::Gene::Site::CodonMap;
use Seq::Tracks::Gene::Definition;
use Seq::DBManager;

########### @Public attributes##########
########### Additional "features" that we will add to our output ##############
### Users may configure these ####

# These are features defined by Gene::Site, but we name them in Seq::Tracks::Gene
# Because it gets really confusing to track down the features defined in Seq::Tracks::Gene::Site
# TODO: rename these siteTypeField to match the interface used by Seq.pm (TODO: and Seq::Tracks::Sparse::Build)
has siteTypeField => (is => 'ro', default => 'siteType');
has strandField => (is => 'ro', default => 'strand');
has codonNumberField => (is => 'ro', default => 'codonNumber');
has codonPositionField => (is => 'ro', default => 'codonPosition');
has codonSequenceField => (is => 'ro', default => 'referenceCodon');

has refAminoAcidField => (is => 'ro', default => 'referenceAminoAcid');
has newCodonField => (is => 'ro', default => 'alleleCodon');
has newAminoAcidField => (is => 'ro', default => 'alleleAminoAcid');
has exonicAlleleFunctionField => (is => 'ro', default => 'exonicAlleleFunction');

########################## Private Attributes ##################################
########## The names of various features. These cannot be configured ##########
### Positions that aren't covered by a refSeq record are intergenic ###
state $intergenic = 'intergenic';

### txEffect possible values ###
# TODO: export these, and make them configurable
state $silent = 'synonymous';
state $replacement = 'nonSynonymous';
state $frameshift = 'indel-frameshift';
state $inFrame = 'indel-nonFrameshift';
state $indelBoundary = 'indel-exonBoundary';
state $startLoss = 'startLoss';
state $stopLoss = 'stopLoss';
state $stopGain = 'stopGain';

# TODO: implement the truncated annotation
state $truncated = 'truncatedCodon';


### objects that get used by multiple subs, but shouldn't be public attributes ###
# All of these instantiated classes cannot be configured at instantiation time
# so safe to use in static context
state $siteUnpacker = Seq::Tracks::Gene::Site->new();
state $siteTypeMap = Seq::Tracks::Gene::Site::SiteTypeMap->new();
state $codonMap = Seq::Tracks::Gene::Site::CodonMap->new();

state $strandIdx = $siteUnpacker->strandIdx;
state $siteTypeIdx = $siteUnpacker->siteTypeIdx;
state $codonSequenceIdx = $siteUnpacker->codonSequenceIdx;
state $codonPositionIdx = $siteUnpacker->codonPositionIdx;
state $codonNumberIdx = $siteUnpacker->codonNumberIdx;

state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub { 
    my $geneDef = Seq::Tracks::Gene::Definition->new();
    return [$geneDef->allUCSCgeneFeatures, $geneDef->txErrorName]; 
  },
);

#### Add our other "features", everything we find for this site ####
sub BUILD {
  my $self = shift;

  # Private variables, meant to cache often used data
  $self->{_allCachedDbNames} = {};
  $self->{_allNearestFieldNames} = {};
  $self->{_allJoinFieldNames} = {};
  $self->{_geneTrackRegionHref} = {};

  # Avoid accessor penalties by aliasing to the $self hash
  # These correspond to all of the sites held in Gene::Site
  $self->{_strandField} = $self->strandField; 
  $self->{_siteTypeField} = $self->siteTypeField;
  $self->{_codonSequenceField} = $self->codonSequenceField;
  $self->{_codonPositionField} = $self->codonPositionField;
  $self->{_codonNumberField} = $self->codonNumberField;

  # The values for these keys we calculate at get() time.
  $self->{_refAminoAcidField} = $self->refAminoAcidField;
  $self->{_newCodonField} = $self->newCodonField;
  $self->{_newAminoAcidField} = $self->newAminoAcidField;
  $self->{_exonicAlleleFunctionField} = $self->exonicAlleleFunctionField;

  $self->{_features} = $self->features;
  $self->{_dbName} = $self->dbName;
  $self->{_db} = Seq::DBManager->new();

  # Not including the txNumberKey;  this is separate from the annotations, which is 
  # what these keys represent

  #  Prepend some internal seqant features
  #  Providing 1 as the last argument means "prepend" instead of append
  #  So these features will come before any other refSeq.* features
  $self->headers->addFeaturesToHeader([
    $self->siteTypeField, $self->exonicAlleleFunctionField,
    $self->codonSequenceField, $self->newCodonField, $self->refAminoAcidField,
    $self->newAminoAcidField, $self->codonPositionField,
    $self->codonNumberField, $self->strandField,
  ], $self->name, 1);

  if(!$self->noNearestFeatures) {
    my $nTrackPrefix = $self->nearestInfix;

    $self->{_hasNearest} = 1;

    $self->{_nearestDbName} = $self->nearestDbName;
    
    $self->{_flatNearestFeatures} = [ map { "$nTrackPrefix.$_" } $self->allNearestFeatureNames ];
    $self->headers->addFeaturesToHeader($self->{_flatNearestFeatures}, $self->name);

    #the features specified in the region database which we want for nearest gene records
    my $i = 0;
    for my $nfName ($self->allNearestFeatureNames) {
      $self->{_allCachedDbNames}{$self->{_flatNearestFeatures}[$i]} = $self->getFieldDbName($nfName);
      $i++;
    }
  }

  if($self->hasJoin) {
    my $joinTrackName = $self->joinTrackName;

    $self->{_hasJoin} = 1;
    
    $self->{_flatJoinFeatures} = [map{ "$joinTrackName.$_" } @{$self->joinTrackFeatures}];
    $self->headers->addFeaturesToHeader($self->{_flatJoinFeatures}, $self->name);

    # TODO: Could theoretically be overwritten by line 114
    #the features specified in the region database which we want for nearest gene records
    my $i = 0;
    for my $fName ( @{$self->joinTrackFeatures} ) {
      $self->{_allCachedDbNames}{$self->{_flatJoinFeatures}[$i]} = $self->getFieldDbName($fName);
      $i++;
    }
  }

  for my $fName (@{$self->{_features}}) {
    $self->{_allCachedDbNames}{$fName} = $self->getFieldDbName($fName);
  }

  my @allGeneTrackFeatures = @{ $self->headers->getParentFeatures($self->name) };
  
  # This includes features added to header, using addFeatureToHeader 
  # such as the modified nearest feature names ($nTrackPrefix.$_) and join track names
  # and siteType, strand, codonNumber, etc.
  for my $i (0 .. $#allGeneTrackFeatures) {
    $self->{_featureIdxMap}{ $allGeneTrackFeatures[$i] } = $i;
  }

  $self->{_lastFeatureIdx} = $#allGeneTrackFeatures;
  # $self->{_featureIdxRange} = [ 0 .. $#allGeneTrackFeatures];
};

sub get {
  my ($self, $href, $chr, $refBase, $allele, $alleleIdx, $positionIdx, $outAccum) = @_;
  
  my @out;
  # Set the out array to the size we need; undef for any indices we don't add here
  $#out = $self->{_lastFeatureIdx};

  # Cached field names to make things easier to read
  my $cachedDbNames = $self->{_allCachedDbNames};
  my $idxMap = $self->{_featureIdxMap};

  ################# Cache track's region data ##############
  $self->{_geneTrackRegionHref}{$chr} //= $self->{_db}->dbReadAll( $self->regionTrackPath($chr) );
  
  my $geneDb = $self->{_geneTrackRegionHref}{$chr};

  ####### Get all transcript numbers, and site data for this position #########

  #<ArrayRef> $unpackedSites ; <ArrayRef|Int> $txNumbers
  my ($siteData, $txNumbers, $multiple);

  #Reads:
  # ( $href->[$self->{_dbName}] ) {
  if( $href->[$self->{_dbName}] ) {
    ($txNumbers, $siteData) = $siteUnpacker->unpack($href->[$self->{_dbName}]);
    $multiple = ref $txNumbers ? $#$txNumbers : 0;
  }

  # ################# Populate nearestGeneSubTrackName ##############
  if($self->{_hasNearest}) {
    # Nearest genes are sub tracks, stored under their own key, based on $self->name
    # <Int|ArrayRef[Int]>
    # If we're in a gene, we won't have a nearest gene reference, but will have a txNumber
    my $nGeneNumber = defined $txNumbers ? $txNumbers : $href->[$self->{_nearestDbName}];

    if(defined $nGeneNumber) {
      # Reads:         ($self->allNearestFeatureNames) {
      for my $nFeature (@{$self->{_flatNearestFeatures}}) {
        $out[ $idxMap->{$nFeature} ] =
          ref $nGeneNumber
          ? [map { $geneDb->{$_}{$cachedDbNames->{$nFeature}} } @$nGeneNumber]
          : $geneDb->{$nGeneNumber}{$cachedDbNames->{$nFeature}};
      }
    } else {
      if($chr ne 'chrM') {
        $self->log('error', "$chr missing nearest gene data");
      }
    }
  }
  
  if( !$txNumbers ) {
    $out[ $idxMap->{$self->{_siteTypeField}} ] = $intergenic;
    
    return accumOut($alleleIdx, $positionIdx, $outAccum, \@out);
  }

  if($self->{_hasJoin}) {
    # For join tracks, use only the entry for the first of multiple transcripts
    # Because the data stored is always identical at one position
    my $num = $multiple ? $txNumbers->[0] : $txNumbers;
    # http://ideone.com/jlImGA
    for my $fName ( @{$self->{_flatJoinFeatures}} ) {
      $out[ $idxMap->{$fName} ] = $geneDb->{$num}{$cachedDbNames->{$fName}};
    }
  }

  ################## Populate site information ########################
  # save unpacked sites, for use in txEffectsKey population #####
  # moose attrs are very slow, cache
  # Push, because we'll use the indexes in calculating alleles
  # TODO: Better handling of truncated codons
  # Avoid a bunch of \;\ for non-coding sites
  # By not setting _codonNumberField, _codonPositionField, _codonSequenceField if !hasCodon
  my $hasCodon;
  if(!$multiple) {
    $out[ $idxMap->{$self->{_strandField}} ] = $siteData->[$strandIdx];
    $out[ $idxMap->{$self->{_siteTypeField}} ] = $siteData->[$siteTypeIdx];

    if(defined $siteData->[$codonSequenceIdx]) {
      $hasCodon = 1;
    }
  } else {
    for my $site (@$siteData) {
      push @{ $out[ $idxMap->{$self->{_strandField}} ] }, $site->[$strandIdx];
      push @{ $out[ $idxMap->{$self->{_siteTypeField}} ] }, $site->[$siteTypeIdx];

      if(defined $site->[$codonSequenceIdx]) {
        $hasCodon //= 1;
      }
    }
  }
  
  # ################# Populate geneTrack's user-defined features #####################
  #Reads:            $self->{_features}
  for my $feature (@{$self->{_features}}) {
    $out[$idxMap->{$feature}] =
      $multiple
      ?  [map { $geneDb->{$_}{$cachedDbNames->{$feature}} } @$txNumbers]
      : $geneDb->{$txNumbers}{$cachedDbNames->{$feature}};
  }

  # If we want to be ~ 20-50% faster, move this before the Populate Gene Tracks section
  if(!$hasCodon) {
    return accumOut($alleleIdx, $positionIdx, $outAccum, \@out);
  }

  ######Populate _codon*Key, exonicAlleleFunction, amion acids keys ############

  my ($i, @funcAccum, @codonNum, @codonSeq, @codonPos, @refAA, @newAA, @newCodon);
  # Set undefs for every position, other than the ones we need
  # So that we don't need to push undef's to keep transcript order
  $#funcAccum = $#codonNum = $#codonSeq = $#codonPos = $#refAA = $#newAA = $#newCodon = $multiple;

  $i = 0;

  if(length($allele) > 1) {
    # Indels get everything besides the _*AminoAcidKey and _newCodonField
    my $indelAllele = 
      substr($allele, 0, 1) eq '+'
      ? length(substr($allele, 1)) % 3 ? $frameshift : $inFrame
      : int($allele) % 3 ? $frameshift : $inFrame; 

    for my $site ($multiple ? @$siteData : $siteData) {
      $codonNum[$i] = $site->[$codonNumberIdx];
      $codonSeq[$i] = $site->[$codonSequenceIdx];

      if(defined $site->[$codonSequenceIdx]) {
        $funcAccum[$i] = $indelAllele;
        
        # Codon position only exists (and always does) when codonSequence does
        # We store codonPosition as 0-based, users probably expect 1 based
        $codonPos[$i] = $site->[$codonPositionIdx] + 1;

        if(length($site->[$codonSequenceIdx]) == 3) {
          $refAA[$i] = $codonMap->codon2aa($site->[$codonSequenceIdx]);
        }
        
        # For indels we don't store newAA or newCodon
      }

      $i++;
    }
  } else {
    # my $newAA;
    # my $refAA;
    my $alleleCodonSequence;

    SNP_LOOP: for my $site ($multiple ? @$siteData : $siteData) {
      $codonNum[$i] = $site->[$codonNumberIdx];
      $codonSeq[$i] = $site->[$codonSequenceIdx];

      if(!defined $site->[$codonSequenceIdx]) {
        $i++;
        next SNP_LOOP;
      }

      # We store as 0-based, users probably expect 1 based
      $codonPos[$i] = $site->[$codonPositionIdx] + 1;

      if(length($site->[$codonSequenceIdx]) != 3) {
        $i++;
        next SNP_LOOP;
      }

      #make a codon where the reference base is swapped for the allele
      $alleleCodonSequence = $site->[$codonSequenceIdx];

      # If codon is on the opposite strand, invert the allele
      # Note that $site->[$codonPositionIdx] MUST be 0-based for this to work
      if( $site->[$strandIdx] eq '-' ) {
        substr($alleleCodonSequence, $site->[$codonPositionIdx], 1) = $negativeStrandTranslation->{$allele};
      } else {
        substr($alleleCodonSequence, $site->[$codonPositionIdx], 1) = $allele;
      }

      $newCodon[$i] = $alleleCodonSequence;

      $newAA[$i] = $codonMap->codon2aa($alleleCodonSequence);
      $refAA[$i] = $codonMap->codon2aa($site->[$codonSequenceIdx]);

      if(!defined $newAA[$i]) {
        $i++;
        next SNP_LOOP;
      }

      if($refAA[$i] eq $newAA[$i]) {
        $funcAccum[$i] = $silent;
      } elsif($newAA[$i] eq '*') {
        $funcAccum[$i] = $stopGain;
      } elsif($refAA[$i] eq '*') {
        $funcAccum[$i] = $stopLoss;
      } else {
        $funcAccum[$i] = $replacement;
      }

      $i++;
    }
  }

  if(!$multiple) {
    $out[ $idxMap->{$self->{_codonPositionField}} ] = $codonPos[0];
    $out[ $idxMap->{$self->{_codonSequenceField}} ] = $codonSeq[0];
    $out[ $idxMap->{$self->{_codonNumberField}} ] = $codonNum[0];
    $out[ $idxMap->{$self->{_exonicAlleleFunctionField}} ] = $funcAccum[0];
    $out[ $idxMap->{$self->{_refAminoAcidField}} ] = $refAA[0];
    $out[ $idxMap->{$self->{_newAminoAcidField}} ] = $newAA[0];
    $out[ $idxMap->{$self->{_newCodonField}} ] = $newCodon[0];
  } else {
    $out[ $idxMap->{$self->{_codonPositionField}} ] = \@codonPos;
    $out[ $idxMap->{$self->{_codonSequenceField}} ] = \@codonSeq;
    $out[ $idxMap->{$self->{_codonNumberField}} ] = \@codonNum;
    $out[ $idxMap->{$self->{_exonicAlleleFunctionField}} ] = \@funcAccum;
    $out[ $idxMap->{$self->{_refAminoAcidField}} ] = \@refAA;
    $out[ $idxMap->{$self->{_newAminoAcidField}} ] = \@newAA;
    $out[ $idxMap->{$self->{_newCodonField}} ] = \@newCodon;
  }

  return accumOut($alleleIdx, $positionIdx, $outAccum, \@out);
};

sub accumOut {
  # my ($alleleIdx, $positionIdx, $outAccum, $outAref) = @_;
  #     $_[0]     , $_[1]       , $_[2]    , $_[3]

  # for my $featureIdx (0 .. $#$outAref) {
  my $i = 0;
  for my $feature (@{$_[3]}) {
    #$outAccum->[$featureIdx][$alleleIdx][$positionIdx] = $outAref->[$featureIdx];
    $_[2]->[$i][$_[0]][$_[1]] = $feature;
    $i++;
  }

  #return $outAccum;
  return $_[2];
}
__PACKAGE__->meta->make_immutable;

1;