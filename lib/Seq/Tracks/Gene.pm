use 5.10.0;
use strict;
use warnings;
# TODO: Think about allowing 3-deep hash
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

### objects that get used by multiple subs, but shouldn't be public attributes ###
# All of these instantiated classes cannot be configured at instantiation time
# so safe to use in static context
state $siteUnpacker = Seq::Tracks::Gene::Site->new();
state $siteTypeMap = Seq::Tracks::Gene::Site::SiteTypeMap->new();
state $codonMap = Seq::Tracks::Gene::Site::CodonMap->new();

### Additional "features" that we will add to our output ###
state $refAminoAcidKey = 'referenceAminoAcid';
state $newCodonKey = 'alleleCodon';
state $newAminoAcidKey = 'alleleAminoAcid';
state $txEffectsKey = 'codonEffect';

### Positions that aren't covered by a refSeq record are intergenic ###
state $intergenic = 'intergenic';

### txEffect possible values ###
state $silent = 'synonymous';
state $replacement = 'nonSynonymous';
state $frameshift = 'frameshift';
state $inFrame = 'nonFrameshift';
state $startLoss = 'startLoss';
state $stopLoss = 'stopLoss';
state $stopGain = 'stopGain';
state $truncated = 'truncatedCodon';

state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };
state $codonSequenceKey = $siteUnpacker->codonSequenceKey;
state $strandIdx = $siteUnpacker->strandIdx;
state $siteTypeIdx = $siteUnpacker->siteTypeIdx;
state $codonSequenceIdx = $siteUnpacker->codonSequenceIdx;
state $codonPositionIdx = $siteUnpacker->codonPositionIdx;
state $codonNumberIdx = $siteUnpacker->codonNumberIdx;

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub { 
    my $geneDef = Seq::Tracks::Gene::Definition->new();
    return [$geneDef->allUCSCgeneFeatures, $geneDef->txErrorName]; 
  },
);

########################### Public attribute exports ###########################
has txEffectsKey => ( is => 'ro', init_arg => undef, lazy => 1, default => sub {$txEffectsKey} );

#### Add our other "features", everything we find for this site ####
sub BUILD {
  my $self = shift;

  # Private variables, meant to cache often used data
  $self->{_allCachedDbNames} = {};
  $self->{_allNearestFieldNames} = {};
  $self->{_allJoinFieldNames} = {};
  $self->{_geneTrackRegionHref} = {};

  $self->{_db} = Seq::DBManager->new();

  # 1 to prepend
  $self->addFeaturesToHeader([$siteUnpacker->siteTypeKey, $txEffectsKey, $siteUnpacker->codonSequenceKey,
    $newCodonKey, $refAminoAcidKey, $newAminoAcidKey, $siteUnpacker->codonPositionKey,
    $siteUnpacker->codonNumberKey, $siteUnpacker->strandKey], $self->name, 1);

  if($self->hasNearest) {
    my $nTrackPrefix = $self->nearestTrackName;

    $self->{_allCachedDbNames}{ $self->nearestTrackName } = $self->nearestDbName;
    
    #the features specified in the region database which we want for nearest gene records
    for my $nearestFeatureName ($self->allNearestFeatureNames) {
      $self->{_allNearestFieldNames}{$nearestFeatureName} = "$nTrackPrefix.$nearestFeatureName";
      $self->{_allCachedDbNames}{$nearestFeatureName} = $self->getFieldDbName($nearestFeatureName);
    }

    $self->addFeaturesToHeader( [ map { "$nTrackPrefix.$_" } $self->allNearestFeatureNames ], $self->name);
  }

  if($self->join) {
    my $joinTrackName = $self->joinTrackName;

    $self->addFeaturesToHeader( [ map { "joinTrackName.$_" } @{$self->joinTrackFeatures} ], $self->name);

    # TODO: ould theoretically be overwritten by line 114
    #the features specified in the region database which we want for nearest gene records
    for my $fName ( @{$self->joinTrackFeatures} ) {
      $self->{_allJoinFieldNames}{$fName} = "joinTrackName.$fName";
      $self->{_allCachedDbNames}{$fName} = $self->getFieldDbName($fName);
    }
  }

  for my $fName ($self->allFeatureNames) {
    $self->{_allCachedDbNames}{$fName} = $self->getFieldDbName($fName);
  }
};

#gets the gene, nearest gene data for the position
#also checks for indels
#@param <String|ArrayRef> $allelesAref : the alleles (including ref potentially)
# that are found in the user's experiment, for this position that we're annotating
#@param <Number> $dbPosition : The 0-index position of the current data
sub get {
  my ($self, $href, $chr, $dbPosition, $refBase, $allelesAref) = @_;

  my %out;

  # Cached field names to make things easier to read
  my $cachedDbNames = $self->{_allCachedDbNames};

  ################# Cache track's region data ##############
  if(!defined $self->{_geneTrackRegionHref}{$chr} ) {
    $self->{_geneTrackRegionHref}{$chr} = $self->{_db}->dbReadAll( $self->regionTrackPath($chr) );
  }
  
  ####### Get all transcript numbers, and site data for this position #########

  #<ArrayRef> $unpackedSites ; <ArrayRef|Int> $txNumbers
  my ($siteData, $txNumbers, $multiple);

  # is an <ArrayRef>, where every other element is siteData
  if( $href->[$self->dbName] ) {
    ($txNumbers, $siteData) = $siteUnpacker->unpack($href->[$self->dbName]);
    $multiple = !! ref $txNumbers;
  }

  # ################# Populate nearestGeneSubTrackName ##############
  if($self->hasNearest) {

    # Nearest genes are sub tracks, stored under their own key, based on $self->name
    # <Int|ArrayRef[Int]>
    # If we're in a gene, we won't have a nearest gene reference
    my $nearestGeneNumber = $txNumbers || $href->[$cachedDbNames->{$self->nearestTrackName}];

    if($nearestGeneNumber) {
      for my $geneRef ( ref $nearestGeneNumber ? @$nearestGeneNumber : $nearestGeneNumber ) {
          for my $nFeature ($self->allNearestFeatureNames) {
            push @{ $out{ $self->{_allNearestFieldNames}{$nFeature} } },
              $self->{_geneTrackRegionHref}{$chr}{$geneRef}{ $cachedDbNames->{$nFeature} };
          }
      }
    }# else { $self->log('warn', "no " . $self->name . " or " . $nearestSubTrackName . " found"); }
  }

  if($txNumbers && $self->join) {
    for my $txNumber(ref $txNumbers ? @$txNumbers : $txNumbers) {
      #the features specified in the region database which we want for nearest gene records
      for my $fName ( @{$self->joinTrackFeatures} ) {
        push @{$out{ $self->{_allJoinFieldNames}{$fName} } },
         $self->{_geneTrackRegionHref}{$chr}{$txNumber}{$cachedDbNames->{$fName} };
      }
    }
  }

  state $siteTypeKey = $siteUnpacker->siteTypeKey;

  if( !$txNumbers ) {
    $out{$siteTypeKey} = $intergenic;
    return \%out;
  }

  ################## Populate site information ########################
  # save unpacked sites, for use in txEffectsKey population #####
  #moose attrs are very slow, cache
  

  my $hasCodon;
  OUTER: for my $site ($multiple ? @$siteData : $siteData) {
    for (my $i = 0; $i < @$site; $i++) {
      if($i == $codonPositionIdx){
        # We store codon position as 0-based, but people probably expect 1-based
        push @{ $out{$siteUnpacker->keysMap->{$i} } }, $site->[$i] + 1;
      } else {
        push @{ $out{$siteUnpacker->keysMap->{$i} } }, $site->[$i];
      }
    }

    #### Populate refAminoAcidKey; note that for a single site
    ###    we can have only one codon sequence, so not need to set array of them ###
    if( defined $site->[$codonSequenceIdx] && length $site->[$codonSequenceIdx] == 3) {
      push @{ $out{$refAminoAcidKey} }, $codonMap->codon2aa( $site->[$codonSequenceIdx] );
      $hasCodon = 1;
    }
  }

  # ################# Populate geneTrack's user-defined features #####################
  foreach ($self->allFeatureNames) {
    INNER: for my $txNumber ($multiple ? @$txNumbers : $txNumbers) {
      push @{ $out{$_} }, $self->{_geneTrackRegionHref}{$chr}{$txNumber}{ $cachedDbNames->{$_} };
    }
  }

  # If we want to be ~ 20-50% faster, move this before the Populate Gene Tracks section
  if(!$hasCodon) {
    return \%out;
  }

  # ################# Populate $transcriptEffectsKey, $newAminoAcidKey #####################
  # ################# We include analysis of indels here, becuase  
  # #############  we may want to know how/if they disturb genes  #####################
  
  # Looping over string, int, or ref: https://ideone.com/4APtzt
  TX_EFFECTS_LOOP: for my $allele (ref $allelesAref ? @$allelesAref : $allelesAref) {
    my @accum;

    if(length($allele) > 1) {
      # We expect either a + or -
      my $type = substr($allele, 0, 1);

      #store as array because our output engine writes [ [one], [two] ] as "1,2"
      push @accum, [ $self->_annotateIndel($chr, $dbPosition, $allele) ];

      next TX_EFFECTS_LOOP;
    }

    ######### Most cases are just snps, so  inline that functionality ##########

    ### We only populate newAminoAcidKey for snps ###
    my $i = 0;
    SNP_LOOP: for my $site ( $multiple ? @$siteData : $siteData ) {
      if(!defined $site->[ $codonPositionIdx ]){
        push @accum, undef;
        push @{ $out{$newAminoAcidKey} }, undef;

        next SNP_LOOP;
      }

      my $refCodonSequence = $out{$codonSequenceKey}[$i];

      if(length($refCodonSequence) != 3) {
        push @accum, $truncated;
        push @{ $out{$newAminoAcidKey} }, undef;
        
        next SNP_LOOP;
      }

      # If codon is on the opposite strand, invert the allele
      if( $site->[$strandIdx] eq '-' ) {
        $allele = $negativeStrandTranslation->{$allele};
      }

      #make a codon where the reference base is swapped for the allele
      my $alleleCodonSequence = $refCodonSequence;

      substr($alleleCodonSequence, $site->[ $codonPositionIdx ], 1 ) = $allele;

      push @{ $out{$newCodonKey} }, $alleleCodonSequence;
      push @{ $out{$newAminoAcidKey} }, $codonMap->codon2aa($alleleCodonSequence);

      if(!defined $out{$newAminoAcidKey}->[$i]) {
        $i++;
        next;
      }

      # If reference codon is same as the allele-substititued version, it's a Silent site
      if( $codonMap->codon2aa($refCodonSequence) eq $out{$newAminoAcidKey}->[$i] ) {
        push @accum, $silent;
      } elsif($out{$newAminoAcidKey}->[$i] eq '*') {
        push @accum, $stopGain;
      } else {
        push @accum, $replacement;
      }

      $i++;
    }

    if(@accum) {
      push @{ $out{$txEffectsKey} }, @accum > 1 ? \@accum : $accum[0];
    }
  }

  return \%out;
};

# TODO: remove the "NA"
sub _annotateIndel {
  my ($self, $chr, $dbPosition, $allele) = @_;

  my $beginning = '';
  my $middle = '';

  my $dbDataAref;

  my $type = substr($allele, 0, 1);
  #### Check if insertion or deletion ###
  if($type eq '+') {
    $beginning = (length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame) . "[";

    # This makes it easier to use a single string building function below.
    $dbDataAref = [ $dbPosition + 1 ];
    #by passing the dbRead function an array, we get an array of data back
    #even if it's one position worth of data
    $self->{_db}->dbRead( $chr, $dbDataAref );
  } elsif($type eq '-') {
    $beginning = ($allele % 3 ? $frameshift : $inFrame) . "[";
    
    #get everything including the current dbPosition, in order to simplify code
    #small perf hit because few indels
    $dbDataAref = [ $dbPosition + $allele .. $dbPosition ];

    # dbRead modifies by reference; each position in dbDataAref gets database data or undef
    # if nothing found
    $self->{_db}->dbRead( $chr, $dbDataAref );
  } else {
    $self->log("warn", "Can't recognize allele $allele on $chr:@{[$dbPosition + 1]}
      as valid indel (must start with - or +)");
    return undef;
  }

  # Will always be an array of dbData, which is to say an array of array presently
  for my $data (@$dbDataAref) {
    if (! defined $data->[$self->dbName] ) {
      #this position doesn't have a gene track, so skip
      $middle .= "$intergenic,";
      next;
    }

    my $siteData = $siteUnpacker->unpack($data->[$self->dbName]);

    # If this position covers multiple transcripts, $siteData will be an array of arrays
      # and if not, it will be a 1D array of scalars
    for my $oneSiteData (ref $siteData->[0] ? @$siteData : $siteData) {
       #Accumulate the annotation. We aren't using Seq::Output to format, because
        #it doesn't fit well with this scheme, in which we prepend FrameShift[ and append ]
        if ( defined $oneSiteData->[ $codonNumberIdx ] && $oneSiteData->[ $codonNumberIdx ] == 1 ) {
          $middle .= "$startLoss;";
        } elsif ( defined $oneSiteData->[ $codonSequenceIdx ]
        &&  defined $codonMap->codon2aa( $oneSiteData->[ $codonSequenceIdx ] )
        &&  $codonMap->codon2aa( $oneSiteData->[ $codonSequenceIdx ] ) eq '*' ) {
          $middle .= "$stopLoss;";
        } else {
          $middle .= $oneSiteData->[ $siteTypeIdx ] . ";";
        }
    }

    chop $middle;
    $middle .= ',';
  }
  
  chop $middle;

  return $beginning . $middle . "]";

}

__PACKAGE__->meta->make_immutable;

1;
