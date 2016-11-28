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
has siteTypeKey => (is => 'ro', default => 'siteType');
has strandKey => (is => 'ro', default => 'strand');
has codonNumberKey => (is => 'ro', default => 'codonNumber');
has codonPositionKey => (is => 'ro', default => 'codonPosition');
has codonSequenceKey => (is => 'ro', default => 'referenceCodon');

has refAminoAcidKey => (is => 'ro', default => 'referenceAminoAcid');
has newCodonKey => (is => 'ro', default => 'alleleCodon');
has newAminoAcidKey => (is => 'ro', default => 'alleleAminoAcid');
has exonicAlleleFunctionKey => (is => 'ro', default => 'exonicAlleleFunction');

################################ Private Attributes ######################################
### objects that get used by multiple subs, but shouldn't be public attributes ###
# All of these instantiated classes cannot be configured at instantiation time
# so safe to use in static context
state $siteUnpacker = Seq::Tracks::Gene::Site->new();
state $siteTypeMap = Seq::Tracks::Gene::Site::SiteTypeMap->new();
state $codonMap = Seq::Tracks::Gene::Site::CodonMap->new();

########## The names of various features. These cannot be configured ##########
### Positions that aren't covered by a refSeq record are intergenic ###
state $intergenic = 'intergenic';

### txEffect possible values ###
state $silent = 'synonymous';
state $replacement = 'nonSynonymous';
state $frameshift = 'indel-frameshift';
state $inFrame = 'indel-nonFrameshift';
state $indelBoundary = 'indel-exonBoundary';
state $startLoss = 'startLoss';
state $stopLoss = 'stopLoss';
state $stopGain = 'stopGain';
state $truncated = 'truncatedCodon';

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
  $self->{_siteTypeKey} = $self->siteTypeKey;
  $self->{_refAminoAcidKey} = $self->refAminoAcidKey;
  $self->{_newCodonKey} = $self->newCodonKey;
  $self->{_newAminoAcidKey} = $self->newAminoAcidKey;
  $self->{_exonicAlleleFunctionKey} = $self->exonicAlleleFunctionKey;
  $self->{_codonSequenceKey} = $self->codonSequenceKey;

  # Avoid Accessor performance hit, these can be called many millions of times
  # in get()
  $self->{_features} = $self->features;
  $self->{_joinTrackFeatures} = $self->joinTrackFeatures;
  $self->{_dbName} = $self->dbName;

  $self->{_db} = Seq::DBManager->new();

  # Not including the txNumberKey;  this is separate from the annotations, which is 
  # what these keys represent
  
  $self->{_siteKeysMap} = { $strandIdx => $self->strandKey, $siteTypeIdx => $self->siteTypeKey,
      $codonNumberIdx => $self->codonNumberKey,  $codonPositionIdx => $self->codonPositionKey,
      $codonSequenceIdx => $self->codonSequenceKey };

  #  Prepend some internal seqant features
  #  Providing 1 as the last argument means "prepend" instead of append
  #  So these features will come before any other refSeq.* features
  $self->addFeaturesToHeader([$self->siteTypeKey, $self->exonicAlleleFunctionKey,
    $self->codonSequenceKey, $self->newCodonKey, $self->refAminoAcidKey,
    $self->newAminoAcidKey, $self->codonPositionKey,
    $self->codonNumberKey, $self->strandKey], $self->name, 1);

  if(!$self->noNearestFeatures) {
    my $nTrackPrefix = $self->nearestTrackName;

    $self->{_allCachedDbNames}{ $self->nearestTrackName } = $self->nearestDbName;
    
    #the features specified in the region database which we want for nearest gene records
    for my $nearestFeatureName ($self->allNearestFeatureNames) {
      $self->{_allCachedDbNames}{$nearestFeatureName} = $self->getFieldDbName($nearestFeatureName);
    }

    $self->addFeaturesToHeader( [ map { "$nTrackPrefix.$_" } $self->allNearestFeatureNames ], $self->name);
    $self->{_nearestFeatureMap} = { map { $_ => "$nTrackPrefix.$_" } $self->allNearestFeatureNames };
  } else {
    $self->{_noNearestFeatures} = 1;
  }

  if($self->hasJoin) {
    my $joinTrackName = $self->joinTrackName;

    $self->{_hasJoin} = 1;
    $self->{_joinTrackFeatureMap} = { map { $_ => "$joinTrackName.$_" } @{ $self->{_joinTrackFeatures} } };

    # Faster to access the hash directly than the accessor
    $self->addFeaturesToHeader( [ map { "$joinTrackName.$_" } @{$self->{_joinTrackFeatures}} ], $self->name );

    # TODO: ould theoretically be overwritten by line 114
    #the features specified in the region database which we want for nearest gene records
    for my $fName ( @{$self->joinTrackFeatures} ) {
      $self->{_allCachedDbNames}{$fName} = $self->getFieldDbName($fName);
    }
  }

  for my $fName (@{$self->{_features}}) {
    $self->{_allCachedDbNames}{$fName} = $self->getFieldDbName($fName);
  }

  my @allGeneTrackFeatures = @{ $self->getParentFeatures($self->name) };
  
  for my $i (0 .. $#allGeneTrackFeatures) {
    $self->{_featureIdxMap}{ $allGeneTrackFeatures[$i] } = $i;
  }

  $self->{_lastFeatureIdx} = $#allGeneTrackFeatures;
};

sub get {
  #These are the arguments passed to this function
  #This function may be called millions of times. To speed up access,
  #Avoid copying the data during sub call
  my ($self, $href, $chr, $refBase, $allelesAref, $outAccum, $alleleNum) = @_;
  #    $_[0]  $_[1]  $_[2] $_[3]     $_[4]
  
  my @out;
  $#out = $self->{_lastFeatureIdx};

  # Cached field names to make things easier to read
  # Reads:            $self->{_allCachedDbNames};
  my $cachedDbNames = $self->{_allCachedDbNames};
  my $idxMap = $self->{_featureIdxMap};

  ################# Cache track's region data ##############
  #Reads:     $geneDb ) {
  $self->{_geneTrackRegionHref}{$chr} //= $self->{_db}->dbReadAll( $self->regionTrackPath($chr) );
  
  my $geneDb = $self->{_geneTrackRegionHref}{$chr};
  ####### Get all transcript numbers, and site data for this position #########

  #<ArrayRef> $unpackedSites ; <ArrayRef|Int> $txNumbers
  my ($siteData, $txNumbers, $multiple);

  #Reads:
  # ( $href->[$self->{_dbName}] ) {
  if( $href->[$self->{_dbName}] ) {
    #Reads:                   $siteUnpacker->unpack($href->[$self->{_dbName}]);
    ($txNumbers, $siteData) = $siteUnpacker->unpack($href->[$self->{_dbName}]);
    $multiple = !! ref $txNumbers;
  }

  # ################# Populate nearestGeneSubTrackName ##############
  # Reads:
  #  $self->{_noNearestFeatures}
  if(!$self->{_noNearestFeatures}) {
    # Nearest genes are sub tracks, stored under their own key, based on $self->name
    # <Int|ArrayRef[Int]>
    # If we're in a gene, we won't have a nearest gene reference
    # Reads: =              $txNumbers || $href->[$cachedDbNames->{$self->nearestTrackName}];
    my $nearestGeneNumber = $txNumbers || $href->[$cachedDbNames->{$self->nearestTrackName}];

    # Reads:         ($self->allNearestFeatureNames) {
    for my $nFeature ($self->allNearestFeatureNames) {
      $out[ $idxMap->{$self->{_nearestFeatureMap}{$nFeature}} ] =
        ref $nearestGeneNumber
        ? [map { $geneDb->{$_}{$cachedDbNames->{$nFeature}} || undef } @$nearestGeneNumber]
        :  $geneDb->{$nearestGeneNumber}{$cachedDbNames->{$nFeature}};
    }
  }

  #Reads:       && $self->{_hasJoin}) {
  if($txNumbers && $self->{_hasJoin}) {
    my $num = $multiple ?  $txNumbers->[0] : $txNumbers;
    # http://ideone.com/jlImGA
    #The features specified in the region database which we want for nearest gene records
    #Reads:         @{$self->{_joinTracksFeatures} }
    for my $fName ( @{$self->{_joinTrackFeatures}} ) {
      $out[ $idxMap->{$self->{_joinTrackFeatureMap}{$fName}} ] = $geneDb->{$num}{$cachedDbNames->{$fName}};
    }
  }
  
  if( !$txNumbers ) {
    #Reads:
    #$out[ $idxMap->{$self->{_siteTypeKey}} ] = $intergenic;
    $out[ $idxMap->{$self->{_siteTypeKey}} ] = $intergenic;
    return $outAccum ? accumOut($outAccum, $alleleNum, \@out) : \@out;
  }

  ################## Populate site information ########################
  # save unpacked sites, for use in txEffectsKey population #####
  # moose attrs are very slow, cache
  # Push, because we'll use the indexes in calculating alleles
  my $hasCodon;
  OUTER: for my $site ($multiple ? @$siteData : $siteData) {
    # faster than c-style loop
    for my $i (0 .. $#$site) {
      if($i == $codonPositionIdx){
        # We store codon position as 0-based, but people probably expect 1-based
        #Reads:      $idxMap->{$self->{_siteKeysMap}{$i}} ]}, $site->[$i] + 1;
        push @{$out[ $idxMap->{$self->{_siteKeysMap}{$i}} ]}, $site->[$i] + 1;
      } else {
        #Reads:      $idxMap->{ $self->{_siteKeysMap}{$i}} ]}, $site->[$i];
        push @{$out[ $idxMap->{ $self->{_siteKeysMap}{$i}} ]}, $site->[$i];
      }
    }

    #### Populate refAminoAcidKey; note that for a single site
    ###    we can have only one codon sequence, so not need to set array of them ###
    if( defined $site->[$codonSequenceIdx] && length $site->[$codonSequenceIdx] == 3) {
      #Reads:      $idxMap->{ $self->{_refAminoAcidKey}} ]}
      push @{$out[ $idxMap->{ $self->{_refAminoAcidKey}} ]}, $codonMap->codon2aa($site->[$codonSequenceIdx]);

      $hasCodon //= 1;
    }
  }

  # ################# Populate geneTrack's user-defined features #####################
  #Reads:            $self->{_features}
  for my $feature (@{$self->{_features}}) {
    $out[$idxMap->{$feature}] =
      $multiple ?  [map { $geneDb->{$_}{$cachedDbNames->{$feature}} || undef } @$txNumbers]
      : $geneDb->{$txNumbers}{$cachedDbNames->{$feature}};
  }

  # If we want to be ~ 20-50% faster, move this before the Populate Gene Tracks section
  if(!$hasCodon) {
    return $outAccum ? accumOut($outAccum, $alleleNum, \@out) : \@out;
  }

  # ################# Populate $transcriptEffectsKey, $self->{_newAminoAcidKey} #####################
  # ################# We include analysis of indels here, becuase  
  # #############  we may want to know how/if they disturb genes  #####################
  
  # WARNING: DO NOT MODIFY $_[4] in the loop. IT WILL MODIFY BY REFERENCE EVEN
  # WHEN SCALAR!!!
  # Looping over string, int, or ref: https://ideone.com/4APtzt
  #Reads:                          ref $allelesAref ? @$allelesAref : $allelesAref
  if(length($_[4]) > 1) {
    $out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ] = 
      substr($_[4], 0, 1) eq '+'  ? length(substr($_[4], 1)) % 3 ? $frameshift : $inFrame
      : int($_[4]) % 3 ? $frameshift : $inFrame; 

    return $outAccum ? accumOut($outAccum, $alleleNum, \@out) : \@out;
  }

  ######### Most cases are just snps, so  inline that functionality ##########

  ### We only populate newAminoAcidKey for snps ###
  my $i = 0;
  my @accum;
  SNP_LOOP: for my $site ( $multiple ? @$siteData : $siteData ) {
    if(!defined $site->[$codonPositionIdx]){
      push @accum, undef;
      #Reads: $out{$self->{_newAminoAcidKey}} }, undef;
      push @{$out[ $idxMap->{$self->{_newAminoAcidKey}} ]}, undef;

      next SNP_LOOP;
    }

    #Reads:                $out{ $idxMap->{ $self->{_codonSequenceKey}}
    my $refCodonSequence = $out[ $idxMap->{ $self->{_codonSequenceKey}} ][$i];

    if(length($refCodonSequence) != 3) {
      push @accum, $truncated;
      #Reads:$out{$self->{_newAminoAcidKey}} }, undef;
      push @{$out[$idxMap->{$self->{_newAminoAcidKey}} ]}, undef;
      
      next SNP_LOOP;
    }

    #make a codon where the reference base is swapped for the allele
    my $alleleCodonSequence = $refCodonSequence;

    # If codon is on the opposite strand, invert the allele
    if( $site->[$strandIdx] eq '-' ) {
      substr($alleleCodonSequence, $site->[$codonPositionIdx], 1) = $negativeStrandTranslation->{$_[4]};
    } else {
      substr($alleleCodonSequence, $site->[$codonPositionIdx], 1) = $_[4];
    }

    #Reads:$out[ $idxMap->{$self->{_newCodonKey}} ], $alleleCodonSequence;
    push @{$out[ $idxMap->{$self->{_newCodonKey}} ]}, $alleleCodonSequence;

    my $newAA = $codonMap->codon2aa($alleleCodonSequence);

    #Reads: $out{$self->{_newAminoAcidKey}} }, $codonMap->codon2aa($alleleCodonSequence);
    push @{$out[ $idxMap->{$self->{_newAminoAcidKey}} ]}, $newAA;

    #Reads:      $out{$self->{_newAminoAcidKey}}->[$i]) {
    if(!defined $newAA) {
      $i++;
      next;
    }

    # If reference codon is same as the allele-substititued version, it's a Silent site
    # Reads:                                      $out{$self->{_newAminoAcidKey}}->[$i] ) {
    if( $codonMap->codon2aa($refCodonSequence) eq $newAA) {
      push @accum, $silent;
    #Reads: $out{$self->{_newAminoAcidKey}}->[$i] eq '*') {
    } elsif($newAA eq '*') {
      push @accum, $stopGain;
    } else {
      push @accum, $replacement;
    }

    $i++;
  }

  if(@accum) {
    #Reads:$idxMap->{$self->{_exonicAlleleFunctionKey}}]
    $out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ] = @accum > 1 ? \@accum : $accum[0];
  }

  return $outAccum ? accumOut($outAccum, $alleleNum, \@out) : \@out;
};

sub accumOut {
  my ($outAccum, $alleleNum, $outAref) = @_;
  
  if($alleleNum == 0) {
    $outAccum = $outAref;

    return $outAccum;
  }

  
  if($alleleNum == 1) {
    for my $part (@$outAccum) {
      $part = [$part];
    }
  }

  for my $i (0 .. $#$outAref) {
    push @{$outAccum->[$i]}, $outAref->[$i] || undef;
  }

  return $outAccum;
}
__PACKAGE__->meta->make_immutable;

1;