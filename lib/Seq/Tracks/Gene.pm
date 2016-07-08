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

use Moose 2;

use namespace::autoclean;
use DDP;

extends 'Seq::Tracks::Get';

use Seq::Tracks::Gene::Site;
use Seq::Tracks::Gene::Site::SiteTypeMap;
use Seq::Tracks::Gene::Site::CodonMap;
use Seq::Tracks::Gene::Definition;

#exports regionTrackPath
with 'Seq::Tracks::Region::RegionTrackPath',

#dbReadAll
'Seq::Role::DBManager';

state $geneDef = Seq::Tracks::Gene::Definition->new();

### objects that get used by multiple subs, but shouldn't be public attributes ###
state $siteUnpacker = Seq::Tracks::Gene::Site->new();
state $siteTypeMap = Seq::Tracks::Gene::Site::SiteTypeMap->new();
state $codonMap = Seq::Tracks::Gene::Site::CodonMap->new();

### Additional "features" that we will add to our output ###
state $refAminoAcidKey = 'referenceAminoAcid';
state $newCodonKey = 'alleleCodon';
state $newAminoAcidKey = 'alleleAminoAcid';
state $txEffectsKey = 'proteinEffect';

### Positions that aren't covered by a refSeq record are intergenic ###
state $intergenic = 'Intergenic';

### txEffect possible values ###
state $nonCoding = 'NonCoding';
state $silent = 'Silent';
state $replacement = 'Replacement';
state $frameshift = 'Frameshift';
state $inFrame = 'InFrame';
state $startLoss = 'StartLoss';
state $stopLoss = 'StopLoss';
state $stopGain = 'StopGain';
state $truncated = 'TruncatedCodon';

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub{ return [$geneDef->allUCSCgeneFeatures, $geneDef->txErrorName]; },
);

### Cache self->getFieldDbName calls to save a bit on performance & improve readability ###
state $allCachedDbNames;

state $nearestSubTrackName;

#### Add our other "features", everything we find for this site ####
sub BUILD {
  my $self = shift;

  # 1 to prepend
  $self->addFeaturesToHeader([$siteUnpacker->siteTypeKey, $txEffectsKey, $siteUnpacker->codonSequenceKey,
    $newCodonKey, $refAminoAcidKey, $newAminoAcidKey, $siteUnpacker->codonPositionKey,
    $siteUnpacker->codonNumberKey, $siteUnpacker->strandKey], $self->name, 1);

  $allCachedDbNames->{$self->name} = {};

  if($self->hasNearest) {
    $nearestSubTrackName = $self->nearestName;

    $allCachedDbNames->{$self->name}{$nearestSubTrackName} = $self->nearestDbName;
  
    $self->addFeaturesToHeader( [ map { "$nearestSubTrackName.$_" } $self->allNearestFeatureNames ], $self->name);

    #the features specified in the region database which we want for nearest gene records
    for my $nearestFeatureName ($self->allNearestFeatureNames) {
      $allCachedDbNames->{$self->name}{$nearestFeatureName} = $self->getFieldDbName($nearestFeatureName);
    }
  }

  for my $featureName ($self->allFeatureNames) {
    $allCachedDbNames->{$self->name}{$featureName} = $self->getFieldDbName($featureName);
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
  my $cachedDbNames = $allCachedDbNames->{$self->name};

  ################# Cache track's region data ##############
  state $geneTrackRegionHref = {};
  if(!defined $geneTrackRegionHref->{$self->name}{$chr} ) {
    $geneTrackRegionHref->{$self->name}{$chr} = $self->dbReadAll( $self->regionTrackPath($chr) );
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
  if(!$self->noNearestFeatures) {
    # Nearest genes are sub tracks, stored under their own key, based on $self->name
    # <Int|ArrayRef[Int]>
    # If we're in a gene, we won't have a nearest gene reference
    my $nearestGeneNumber = $txNumbers || $href->[$cachedDbNames->{$nearestSubTrackName}];

    if($nearestGeneNumber) {
      for my $geneRef ( ref $nearestGeneNumber ? @$nearestGeneNumber : $nearestGeneNumber ) {
          for my $nFeature ($self->allNearestFeatureNames) {
            push @{ $out{"$nearestSubTrackName.$nFeature"} },
              $geneTrackRegionHref->{$self->name}{$chr}{$geneRef}{ $cachedDbNames->{$nFeature} };
          }
      }
    }# else { $self->log('warn', "no " . $self->name . " or " . $nearestSubTrackName . " found"); }
  }

  state $siteTypeKey = $siteUnpacker->siteTypeKey;

  if( !$txNumbers ) {
    $out{$siteTypeKey} = $intergenic;
    return \%out;
  }

  ################## Populate site information ########################
  # save unpacked sites, for use in txEffectsKey population #####
  #moose attrs are very slow, cache
  state $codonSequenceIdx = $siteUnpacker->codonSequenceIdx;
  state $codonPositionIdx = $siteUnpacker->codonPositionIdx;

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
      push @{ $out{$_} }, $geneTrackRegionHref->{$self->name}{$chr}{$txNumber}{ $cachedDbNames->{$_} };
    }
  }

  # If we want to be ~ 20-50% faster, move this before the Populate Gene Tracks section
  if(!$hasCodon) {
    return \%out;
  }

  # ################# Populate $transcriptEffectsKey, $newAminoAcidKey #####################
  # ################# We include analysis of indels here, becuase  
  # #############  we may want to know how/if they disturb genes  #####################

  state $codonSequenceKey = $siteUnpacker->codonSequenceKey;
  state $strandIdx = $siteUnpacker->strandIdx;
  
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
    state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };

    ### We only populate newAminoAcidKey for snps ###
    my $i = 0;
    SNP_LOOP: for my $site ( $multiple ? @$siteData : $siteData ) {
      if(!defined $site->[ $codonPositionIdx ]){
        push @accum, $nonCoding;
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

sub _annotateIndel {
  my ($self, $chr, $dbPosition, $allele) = @_;

  my $beginning = '';
  my $middle = '';

  my $dbDataAref;

  my $type = substr($allele, 0, 1);
  #### Check if insertion or deletion ###
  if($type eq '+') {
    $beginning = (length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame) . "[";

    #by passing the dbRead function an array, we get an array of data back
    #even if it's one position worth of data
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + 1 ] );
  } elsif($type eq '-') {
    $beginning = ($allele % 3 ? $frameshift : $inFrame) . "[";
    
    #get everything including the current dbPosition, in order to simplify code
    #small perf hit because few indels
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + $allele .. $dbPosition ] );
  } else {
    $self->log("warn", "Can't recognize allele $allele on $chr:@{[$dbPosition + 1]}
      as valid indel (must start with - or +)");
    return undef;
  }

  for my $data (@$dbDataAref) {
    if (! defined $data->[$self->dbName] ) {
      #this position doesn't have a gene track, so skip
      $middle .= "$intergenic";
      next;
    }
   
    ####### Get all transcript numbers, and site data for this position #########
    my $siteData;

    # is an <ArrayRef[ArrayRef>|ArrayRef[Int]>, each Aref is [$referenceNumberToRegionDatabase, $siteData] ]
    if( $data->[$self->dbName] ) {
      if( ref $data->[$self->dbName][0] ) {
        foreach ( @{ $data->[$self->dbName] } ) {
          push @$siteData, $_->[1];
        }
      } else {
        $siteData = $data->[$self->dbName][1]; 
      }
    }

    for my $oneSiteData (ref $siteData eq 'ARRAY' ? @$siteData : $siteData) {
      my $site = $siteUnpacker->unpackCodon($oneSiteData);

      #Accumulate the annotation. We aren't using Seq::Output to format, because
      #it doesn't fit well with this scheme, in which we prepend FrameShift[ and append ]
      if ( defined $site->{ $siteUnpacker->codonNumberKey } && $site->{ $siteUnpacker->codonNumberKey } == 1 ) {
        $middle .= "$startLoss;";
      } elsif ( defined $site->{ $siteUnpacker->codonSequenceKey }
      &&  $codonMap->codon2aa( $site->{ $siteUnpacker->codonSequenceKey } ) eq '*' ) {
        $middle .= "$stopLoss;";
      } else {
        $middle .= $site->{ $siteUnpacker->siteTypeKey } . ";";
      }
    }
  }
  
  chop $middle;

  return $beginning . $middle . "]";
}

__PACKAGE__->meta->make_immutable;

1;
