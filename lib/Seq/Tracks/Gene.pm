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
  # These correspond to all of the sites held in Gene::Site
  $self->{_strandKey} = $self->strandKey; 
  $self->{_siteTypeKey} = $self->siteTypeKey;
  $self->{_codonSequenceKey} = $self->codonSequenceKey;
  $self->{_codonPositionKey} = $self->codonPositionKey;
  $self->{_codonNumberKey} = $self->codonNumberKey;

  # The values for these keys we calculate at get() time.
  $self->{_refAminoAcidKey} = $self->refAminoAcidKey;
  $self->{_newCodonKey} = $self->newCodonKey;
  $self->{_newAminoAcidKey} = $self->newAminoAcidKey;
  $self->{_exonicAlleleFunctionKey} = $self->exonicAlleleFunctionKey;

  # Avoid Accessor performance hit, these can be called many millions of times
  # in get()
  $self->{_features} = $self->features;
  $self->{_joinTrackFeatures} = $self->joinTrackFeatures;
  $self->{_dbName} = $self->dbName;

  $self->{_db} = Seq::DBManager->new();

  # Not including the txNumberKey;  this is separate from the annotations, which is 
  # what these keys represent

  #  Prepend some internal seqant features
  #  Providing 1 as the last argument means "prepend" instead of append
  #  So these features will come before any other refSeq.* features
  $self->addFeaturesToHeader([$self->siteTypeKey, $self->exonicAlleleFunctionKey,
    $self->codonSequenceKey, $self->newCodonKey, $self->refAminoAcidKey,
    $self->newAminoAcidKey, $self->codonPositionKey,
    $self->codonNumberKey, $self->strandKey], $self->name, 1);

  if(!$self->noNearestFeatures) {
    my $nTrackPrefix = $self->nearestTrackName;

    $self->{_hasNearest} = 1;

    $self->{_allCachedDbNames}{ $self->nearestTrackName } = $self->nearestDbName;
    
    $self->{_flatNearestFeatures} = [ map { "$nTrackPrefix.$_" } $self->allNearestFeatureNames ];
    $self->addFeaturesToHeader($self->{_flatNearestFeatures}, $self->name);

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
    
    $self->{_flatJoinFeatures} = [map{ "$joinTrackName.$_" } @{ $self->{_joinTrackFeatures} }];
    $self->addFeaturesToHeader($self->{_flatJoinFeatures}, $self->name);

    # TODO: ould theoretically be overwritten by line 114
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

  my @allGeneTrackFeatures = @{ $self->getParentFeatures($self->name) };
  
  # This includes features added to header, using addFeatureToHeader 
  # such as the modified nearest feature names ($nTrackPrefix.$_) and join track names
  # and siteType, strand, codonNumber, etc.
  for my $i (0 .. $#allGeneTrackFeatures) {
    $self->{_featureIdxMap}{ $allGeneTrackFeatures[$i] } = $i;
  }

  $self->{_lastFeatureIdx} = $#allGeneTrackFeatures;

  ################## Pre-fetch all gene track data ########################
  # saves memory, costs startup time for small jobs
  # $self->{_geneTrackRegionHref} = { map { 
  #   $_ => $self->{_db}->dbReadAll($self->regionTrackPath($_))
  # } $self->allWantedChrs() };
};

sub get {
  #These are the arguments passed to this function
  #This function may be called millions of times. To speed up access,
  #Avoid copying the data during sub call
  my ($self, $href, $chr, $refBase, $allele, $alleleIdx, $positionIdx, $outAccum) = @_;
  #    $_[0]  $_[1]  $_[2] $_[3]    $_[4]
  
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
  if($self->{_hasNearest}) {
    # Nearest genes are sub tracks, stored under their own key, based on $self->name
    # <Int|ArrayRef[Int]>
    # If we're in a gene, we won't have a nearest gene reference, but will have a txNumber
    my $nearestGeneNumber =
      defined $txNumbers
      ? $txNumbers 
      : $href->[$cachedDbNames->{$self->nearestTrackName}];

    # Reads:         ($self->allNearestFeatureNames) {
    for my $nFeature (@{$self->{_flatNearestFeatures}}) {
      $out[ $idxMap->{$nFeature} ] =
        ref $nearestGeneNumber
        ? [map { $geneDb->{$_}{$cachedDbNames->{$nFeature}} } @$nearestGeneNumber]
        : $geneDb->{$nearestGeneNumber}{$cachedDbNames->{$nFeature}};
    }
  }

  #Reads:       && $self->{_hasJoin}) {
  if($txNumbers && $self->{_hasJoin}) {
    my $num = $multiple ?  $txNumbers->[0] : $txNumbers;
    # http://ideone.com/jlImGA
    #The features specified in the region database which we want for nearest gene records
    #Reads:         @{$self->{_flatJoinFeatures} }
    for my $fName ( @{$self->{_flatJoinFeatures}} ) {
      $out[ $idxMap->{$fName} ] = $geneDb->{$num}{$cachedDbNames->{$fName}};
    }
  }
  
  if( !$txNumbers ) {
    #Reads:
    #$out[ $idxMap->{$self->{_siteTypeKey}} ] = $intergenic;
    $out[ $idxMap->{$self->{_siteTypeKey}} ] = $intergenic;
    return $outAccum ? accumOut($alleleIdx, $positionIdx, $outAccum, \@out) : \@out;
  }

  ################## Populate site information ########################
  # save unpacked sites, for use in txEffectsKey population #####
  # moose attrs are very slow, cache
  # Push, because we'll use the indexes in calculating alleles
  # TODO: Better handling of truncated codons
  # Avoid a bunch of \;\ for non-coding sites
  # By not assigning until the lower SNP_LOOP:
  # $out[ $idxMap->{$self->{_codonNumberKey}} ];
  # $out[ $idxMap->{$self->{_codonPositionKey}} ];
  # $out[ $idxMap->{$self->{_codonSequenceKey}} ];
  my $hasCodon;
  if(!$multiple) {
    $out[ $idxMap->{$self->{_strandKey}} ] = $siteData->[$strandIdx];
    $out[ $idxMap->{$self->{_siteTypeKey}} ] = $siteData->[$siteTypeIdx];

    # Only call codon2aa if needed; 
    # TODO: What to do when truncated codon
    if(defined $siteData->[$codonSequenceIdx]) {
      $hasCodon = 1;
    }
  } else {
    for my $site (@$siteData) {
      push @{ $out[ $idxMap->{$self->{_strandKey}} ] }, $site->[$strandIdx];
      push @{ $out[ $idxMap->{$self->{_siteTypeKey}} ] }, $site->[$siteTypeIdx];

      # TODO: what to do when truncated codon
      # Push an undef if nothing found, to keep multiple site data in transcript order
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
    return $outAccum ? accumOut($alleleIdx, $positionIdx, $outAccum, \@out) : \@out;
  }

  # ################# Populate $transcriptEffectsKey, $self->{_newAminoAcidKey} #####################
  # ################# We include analysis of indels here, becuase  
  # #############  we may want to know how/if they disturb genes  #####################
  
  # TODO: Populate exonicAlleleFunction more than once for indels?
  # It seems kind of silly to keep them in txOrder, since the annotation is
  # always the same.
  if(length($allele) > 1) {
    my $indelAllele = 
      substr($allele, 0, 1) eq '+'
      ? length(substr($allele, 1)) % 3 ? $frameshift : $inFrame
      : int($allele) % 3 ? $frameshift : $inFrame; 

    if($multiple) {
      SNP_LOOP: for my $site ( $multiple ? @$siteData : $siteData ) {
        push @{ $out[ $idxMap->{$self->{_codonNumberKey}} ] }, $site->[$codonNumberIdx];
          # We store as 0-based, users probably expect 1 based
        push @{ $out[ $idxMap->{$self->{_codonPositionKey}} ] },
          $site->[$codonPositionIdx] ? $site->[$codonPositionIdx] + 1 : undef;
        push @{ $out[ $idxMap->{$self->{_codonSequenceKey}} ] }, $site->[$codonSequenceIdx];

        push @{$out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ]}, 
          defined $site->[$codonSequenceIdx] ? $indelAllele : undef;
      }
    }else {
      $out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ] = $indelAllele;
    }

    return $outAccum ? accumOut($alleleIdx, $positionIdx, $outAccum, \@out) : \@out;
  }

  ######### Most cases are just snps, so  inline that functionality ##########

  my $i = 0;
  my @funcAccum;
  my $newAA;
  my $refAA;
  SNP_LOOP: for my $site ( $multiple ? @$siteData : $siteData ) {
    push @{ $out[ $idxMap->{$self->{_codonNumberKey}} ] }, $site->[$codonNumberIdx];
      # We store as 0-based, users probably expect 1 based
    push @{ $out[ $idxMap->{$self->{_codonPositionKey}} ] },
      $site->[$codonPositionIdx] ? $site->[$codonPositionIdx] + 1 : undef;
    push @{ $out[ $idxMap->{$self->{_codonSequenceKey}} ] }, $site->[$codonSequenceIdx];

    if( !(defined $site->[$codonSequenceIdx] && length($site->[$codonSequenceIdx]) == 3
    && defined $site->[$codonPositionIdx]) ) {
      # We only need to push undef, because (since our $out is expanded to num of features)
      # We default to scalar undef for every field
      if($multiple) {
        push @funcAccum, undef;
        push @{$out[ $idxMap->{$self->{_refAminoAcidKey}} ]}, undef;
        push @{$out[ $idxMap->{$self->{_newAminoAcidKey}} ]}, undef;
        push @{$out[ $idxMap->{$self->{_newCodonKey}} ]}, undef;

        # say "didn't find things, out for $allele with this number of sites: " . scalar @$siteData;
        # p @out;
        # p $siteData;

        # p $idxMap;
      }
      
      $i++;
      next SNP_LOOP;
    }

    #make a codon where the reference base is swapped for the allele
    my $alleleCodonSequence = $site->[$codonSequenceIdx];

    # If codon is on the opposite strand, invert the allele
    if( $site->[$strandIdx] eq '-' ) {
      substr($alleleCodonSequence, $site->[$codonPositionIdx], 1) = $negativeStrandTranslation->{$allele};
    } else {
      substr($alleleCodonSequence, $site->[$codonPositionIdx], 1) = $allele;
    }

    $newAA = $codonMap->codon2aa($alleleCodonSequence);
    $refAA = $codonMap->codon2aa($site->[$codonSequenceIdx]);

    if($multiple) {
      push @{$out[ $idxMap->{$self->{_refAminoAcidKey}} ]}, $refAA;
      push @{$out[ $idxMap->{$self->{_newCodonKey}} ]}, $alleleCodonSequence;
      push @{$out[ $idxMap->{$self->{_newAminoAcidKey}} ]}, $newAA;
    } else {
      $out[ $idxMap->{$self->{_refAminoAcidKey}} ] = $refAA;
      $out[ $idxMap->{$self->{_newCodonKey}} ] = $alleleCodonSequence;
      $out[ $idxMap->{$self->{_newAminoAcidKey}} ] = $newAA;
    }
    
    if(!defined $newAA) {
      if($multiple) {
        push @funcAccum, undef;
      }

      $i++;
      next;
    }

    if($refAA eq $newAA) {
      push @funcAccum, $silent;
    } elsif($newAA eq '*') {
      push @funcAccum, $stopGain;
    } elsif($refAA eq '*') {
      push @funcAccum, $stopLoss;
    } else {
      push @funcAccum, $replacement;
    }

    $i++;
  }

  $out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ] = @funcAccum > 1 ? \@funcAccum : $funcAccum[0];

  # if(@funcAccum) {
  #   #Reads:$idxMap->{$self->{_exonicAlleleFunctionKey}}]
  #   $out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ] = @funcAccum > 1 ? \@funcAccum : $funcAccum[0];
  # } else {
  #   $out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ] = [undef] x @$txNumbers;

  #   say "I did stuff";
  #   p $out[ $idxMap->{$self->{_exonicAlleleFunctionKey}} ] ;
  # }

  return $outAccum ? accumOut($alleleIdx, $positionIdx, $outAccum, \@out) : \@out;
};

sub accumOut {
  # my ($alleleIdx, $positionIdx, $outAccum, $outAref) = @_;
  #     $_[0]     , $_[1]       , $_[2]    , $_[3]

  # for my $featureIdx (0 .. $#$outAref) {
  for my $featureIdx (0 .. $#{$_[3]}) {
    #$outAccum->[$featureIdx][$alleleIdx][$positionIdx] = $outAref->[$featureIdx];
    $_[2]->[$featureIdx][$_[0]][$_[1]] = $_[3]->[$featureIdx] || undef;
  }

  #return $outAccum;
  return $_[2];
}
__PACKAGE__->meta->make_immutable;

1;