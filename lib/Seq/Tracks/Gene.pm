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
has exonNumberKey => (is => 'ro', default => 'exonNumber');

# Will be refSeq.nearest.distance for instance
# has nearestDistanceKeyPart => (is => 'ro', default => 'distance');
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
state $frameshift = 'frameshift';
state $inFrame = 'nonFrameshift';
state $startLoss = 'startLoss';
state $stopLoss = 'stopLoss';
state $stopGain = 'stopGain';
state $truncated = 'truncatedCodon';

state $strandIdx = $siteUnpacker->strandIdx;
state $siteTypeIdx = $siteUnpacker->siteTypeIdx;
state $exonNumberIdx = $siteUnpacker->exonNumberIdx;
state $codonSequenceIdx = $siteUnpacker->codonSequenceIdx;
state $codonPositionIdx = $siteUnpacker->codonPositionIdx;
state $codonNumberIdx = $siteUnpacker->codonNumberIdx;

state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub { 
    my $geneDef = Seq::Tracks::Gene::Definition->new();
    return [$geneDef->allUCSCgeneFeatures, $geneDef->txErrorName, $geneDef->txSizeName]; 
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

  $self->{_hasNearest} = $self->hasNearest;
  $self->{_hasJoin} = $self->hasJoin;

  # Not including the txNumberKey;  this is separate from the annotations, which is 
  # what these keys represent
  
  $self->{_keysMap} = { $strandIdx => $self->strandKey, $siteTypeIdx => $self->siteTypeKey,
      $exonNumberIdx => $self->exonNumberKey,
      $codonNumberIdx => $self->codonNumberKey,  $codonPositionIdx => $self->codonPositionKey,
      $codonSequenceIdx => $self->codonSequenceKey };

  $self->{_db} = Seq::DBManager->new();

  #  Prepend some internal seqant features
  #  Providing 1 as the last argument means "prepend" instead of append
  #  So these features will come before any other refSeq.* features
  $self->addFeaturesToHeader([$self->siteTypeKey, $self->strandKey, $self->exonNumberKey,
    $self->exonicAlleleFunctionKey,
    $self->codonSequenceKey, $self->newCodonKey, $self->refAminoAcidKey,
    $self->newAminoAcidKey, $self->codonPositionKey,
    $self->codonNumberKey], $self->name, 1);

  if($self->hasNearest) {
    my $nTrackPrefix = $self->nearestTrackName;

    $self->{_allCachedDbNames}{ $self->nearestTrackName } = $self->nearestDbName;
    $self->{_allNearestFeatureNames} = [ $self->allNearestFeatureNames ];

    #the features specified in the region database which we want for nearest gene records
    for my $nearestFeatureName ($self->allNearestFeatureNames) {
      $self->{_allNearestFieldNames}{$nearestFeatureName} = "$nTrackPrefix.$nearestFeatureName";
      $self->{_allCachedDbNames}{$nearestFeatureName} = $self->getFieldDbName($nearestFeatureName);
    }
    # $self->{_nearestDistKey} = $nTrackPrefix . "." . $self->nearestDistanceKeyPart;
    $self->addFeaturesToHeader( [ map { "$nTrackPrefix.$_" } $self->allNearestFeatureNames ], $self->name);
  }

  if($self->join) {
    my $joinTrackName = $self->joinTrackName;

    # Faster to access the hash directly than the accessor
    $self->addFeaturesToHeader( [ map { "$joinTrackName.$_" } @{$self->{_joinTrackFeatures}} ],
      $self->name);

    # TODO: ould theoretically be overwritten by line 114
    #the features specified in the region database which we want for nearest gene records
    for my $fName ( @{$self->joinTrackFeatures} ) {
      $self->{_allJoinFieldNames}{$fName} = "$joinTrackName.$fName";
      $self->{_allCachedDbNames}{$fName} = $self->getFieldDbName($fName);
    }
  }

  for my $fName (@{$self->{_features}}) {
    $self->{_allCachedDbNames}{$fName} = $self->getFieldDbName($fName);
  }
};

#gets the gene, nearest gene data for the position
#also checks for indels
#@param <String|ArrayRef> $allelesAref : the alleles (including ref potentially)
# that are found in the user's experiment, for this position that we're annotating
#@param <Number> $dbPosition : The 0-index position of the current data
sub get {
  #These are the arguments passed to this function
  #This function may be called millions of times. To speed up access,
  #Avoid copying the data during sub call
  #my ($self, $href, $chr, $dbPosition, $refBase, $allelesAref) = @_;
  #    $_[0]  $_[1]  $_[2]  $_[3]       $_[4]     $_[5]
  
  my %out;

  # Cached field names to make things easier to read
  # Reads:            $self->{_allCachedDbNames};
  my $cachedDbNames = $_[0]->{_allCachedDbNames};

  ################# Cache track's region data ##############
  #Reads:     $self->{_geneTrackRegionHref}{$chr} ) {
  if(!defined $_[0]->{_geneTrackRegionHref}{$_[2]} ) {
    #Reads:
    #$self->{_geneTrackRegionHref}{$chr} = $self->{_db}->dbReadAll( $self->regionTrackPath($chr) );
    $_[0]->{_geneTrackRegionHref}{$_[2]} = $_[0]->{_db}->dbReadAll( $_[0]->regionTrackPath($_[2]) );
  }
  
  ####### Get all transcript numbers, and site data for this position #########

  #<ArrayRef> $unpackedSites ; <ArrayRef|Int> $txNumbers
  my ($siteData, $txNumbers, $multiple);

  #Reads:
  # ( $href->[$self->{_dbName}] ) {
  if( $_[1]->[$_[0]->{_dbName}] ) {
    #Reads:                   $siteUnpacker->unpack($href->[$self->{_dbName}]);
    ($txNumbers, $siteData) = $siteUnpacker->unpack($_[1]->[$_[0]->{_dbName}]);
    $multiple = !! ref $txNumbers;
  }

  # ################# Populate nearestGeneSubTrackName ##############
  # Reads:
  #  $self->{_hasNearest}
  if($_[0]->{_hasNearest}) {

    # Nearest genes are sub tracks, stored under their own key, based on $self->name
    # <Int|ArrayRef[Int]>
    # If we're in a gene, we won't have a nearest gene reference
    # Reads: =              $txNumbers || $href->[$cachedDbNames->{$self->nearestTrackName}];
    my $nearestGeneNumber = $txNumbers || $_[1]->[$cachedDbNames->{$_[0]->nearestTrackName}];

      for my $geneRef ( ref $nearestGeneNumber ? $nearestGeneNumber : $nearestGeneNumber ) {
          # Reads:         ($self->{_allNearestFeatureNames}) {
          for my $nFeature ( @{$_[0]->{_allNearestFeatureNames}} ) {
            #Reads:
            #push @{ $out{ $self->{_allNearestFieldNames}{$nFeature} } }, 
            push @{ $out{ $_[0]->{_allNearestFieldNames}{$nFeature} } },
            $_[0]->{_geneTrackRegionHref}{$_[2]}{$geneRef}{$cachedDbNames->{$nFeature}};
            #$self->{_geneTrackRegionHref}{$chr}{$geneRef}{$cachedDbNames->{$nFeature}};
          }
      }
  }

  #Reads:       && $self->join) {
  if($txNumbers && $_[0]->{_hasJoin}) {
    for my $txNumber(ref $txNumbers ? $txNumbers->[0] : $txNumbers) {
      #The features specified in the region database which we want for nearest gene records
      #Reads:         @{$self->{_joinTracksFeatures} }
      for my $fName ( @{$_[0]->{_joinTrackFeatures}} ) {
        #Reads       $self->{_allJoinFieldNames}{$fName} } },
        push @{$out{ $_[0]->{_allJoinFieldNames}{$fName} } },
        #Reads
        #$self->{_geneTrackRegionHref}{$chr}{$txNumber}{$cachedDbNames->{$fName} };
         $_[0]->{_geneTrackRegionHref}{$_[2]}{$txNumber}{$cachedDbNames->{$fName} };
      }
    }
  }

  if( !$txNumbers ) {
    #Reads:
    #$out{$self->{_siteTypeKey}} = $intergenic;
    $out{$_[0]->{_siteTypeKey}} = $intergenic;
    return \%out;
  }

  ################## Populate site information ########################
  # save unpacked sites, for use in txEffectsKey population #####
  # moose attrs are very slow, cache

  my $hasCodon;
  OUTER: for my $site ($multiple ? @$siteData : $siteData) {
    for (my $i = 0; $i < @$site; $i++) {
      if($i == $codonPositionIdx){
        # We store codon position as 0-based, but people probably expect 1-based
        #Reads:      $self->{_keysMap}{$i}
        push @{ $out{$_[0]->{_keysMap}{$i}} }, $site->[$i] + 1;
      } else {
        #Reads:      $self->{_keysMap}{$i}
        push @{ $out{$_[0]->{_keysMap}{$i} } }, $site->[$i];
      }
    }

    #### Populate refAminoAcidKey; note that for a single site
    ###    we can have only one codon sequence, so not need to set array of them ###
    if( defined $site->[$codonSequenceIdx] && length $site->[$codonSequenceIdx] == 3) {
      #Reads:      $self->{_refAminoAcidKey}
      push @{ $out{$_[0]->{_refAminoAcidKey}} }, $codonMap->codon2aa( $site->[$codonSequenceIdx] );
      $hasCodon = 1;
    }
  }

  # ################# Populate geneTrack's user-defined features #####################
  #Reads:            $self->{_features}
  for my $feature (@{$_[0]->{_features}}) {
    INNER: for my $txNumber ($multiple ? @$txNumbers : $txNumbers) {
      #Reads:                   $self->{_geneTrackRegionHref}{$chr}{$txNumber}{ $cachedDbNames->{$feature} };
      push @{ $out{$feature} }, $_[0]->{_geneTrackRegionHref}{$_[2]}{$txNumber}{ $cachedDbNames->{$feature} };
    }
  }

  # If we want to be ~ 20-50% faster, move this before the Populate Gene Tracks section
  if(!$hasCodon) {
    return \%out;
  }

  # ################# Populate $transcriptEffectsKey, $self->{_newAminoAcidKey} #####################
  # ################# We include analysis of indels here, becuase  
  # #############  we may want to know how/if they disturb genes  #####################
  
  # WARNING: DO NOT MODIFY $_[5] in the loop. IT WILL MODIFY BY REFERENCE EVEN
  # WHEN SCALAR!!!
  # Looping over string, int, or ref: https://ideone.com/4APtzt
  #Reads:                          ref $allelesAref ? @$allelesAref : $allelesAref
  TX_EFFECTS_LOOP: for my $allele (ref $_[5] ? @{$_[5]} : $_[5]) {
    my @accum;

    if(length($allele) > 1) {
      # We expect either a + or -
      my $type = substr($allele, 0, 1);

      #store as array because our output engine writes [ [one], [two] ] as "1,2"
      #Reads:      [ $self->_annotateIndel($chr, $dbPosition, $allele) ];
      push @accum, [ $_[0]->_annotateIndel($_[2], $_[3], $allele) ];

      next TX_EFFECTS_LOOP;
    }

    ######### Most cases are just snps, so  inline that functionality ##########

    ### We only populate newAminoAcidKey for snps ###
    my $i = 0;
    SNP_LOOP: for my $site ( $multiple ? @$siteData : $siteData ) {
      if(!defined $site->[ $codonPositionIdx ]){
        push @accum, undef;
        #Reads: $out{$self->{_newAminoAcidKey}} }, undef;
        push @{ $out{$_[0]->{_newAminoAcidKey}} }, undef;

        next SNP_LOOP;
      }

      #Reads:                $out{ $self->{_codonSequenceKey} }[$i];
      my $refCodonSequence = $out{ $_[0]->{_codonSequenceKey} }[$i];

      if(length($refCodonSequence) != 3) {
        push @accum, $truncated;
        #Reads: $out{$self->{_newAminoAcidKey}} }, undef;
        push @{ $out{$_[0]->{_newAminoAcidKey}} }, undef;
        
        next SNP_LOOP;
      }

      #make a codon where the reference base is swapped for the allele
      my $alleleCodonSequence = $refCodonSequence;

      # If codon is on the opposite strand, invert the allele
      if( $site->[$strandIdx] eq '-' ) {
        substr($alleleCodonSequence, $site->[ $codonPositionIdx ], 1 ) = $negativeStrandTranslation->{$allele};
      } else {
        substr($alleleCodonSequence, $site->[ $codonPositionIdx ], 1 ) = $allele;
      }

      #Reads: $out{$self->{_newCodonKey}} }, $alleleCodonSequence;
      push @{ $out{$_[0]->{_newCodonKey}} }, $alleleCodonSequence;
      #Reads: $out{$self->{_newAminoAcidKey}} }, $codonMap->codon2aa($alleleCodonSequence);
      push @{ $out{$_[0]->{_newAminoAcidKey}} }, $codonMap->codon2aa($alleleCodonSequence);

      #Reads:      $out{$self->{_newAminoAcidKey}}->[$i]) {
      if(!defined $out{$_[0]->{_newAminoAcidKey}}->[$i]) {
        $i++;
        next;
      }

      # If reference codon is same as the allele-substititued version, it's a Silent site
      # Reads:                                      $out{$self->{_newAminoAcidKey}}->[$i] ) {
      if( $codonMap->codon2aa($refCodonSequence) eq $out{$_[0]->{_newAminoAcidKey}}->[$i] ) {
        push @accum, $silent;
      #Reads: $out{$self->{_newAminoAcidKey}}->[$i] eq '*') {
      } elsif($out{$_[0]->{_newAminoAcidKey}}->[$i] eq '*') {
        push @accum, $stopGain;
      } else {
        push @accum, $replacement;
      }

      $i++;
    }

    if(@accum) {
      #Reads:     $self->{_exonicAlleleFunctionKey}}}, @accum > 1 ? \@accum : $accum[0];
      push @{$out{$_[0]->{_exonicAlleleFunctionKey}}}, @accum > 1 ? \@accum : $accum[0];
    }
  }

  return \%out;
};

# TODO: remove the "NA"
sub _annotateIndel {
  #To speed up this function call, avoid assigning these strings
  #my ($self, $chr, $dbPosition, $allele) = @_;
  #    $_[0], $_[1]. $_[2],      $_[3]

  my $beginning = '';
  my $middle = '';

  my $dbDataAref;

  #Reads:           $allele,   0, 1);
  my $type = substr($_[3], 0, 1);
  #### Check if insertion or deletion ###

  ##################### If the site is an insertion ############################
  #If it's an insetion, we only get the next upstream position
  #It is difficult to predict the effects of an insertion, so for now we've just
  #elected to take the annotaiton of the next upstream site, and then also check
  #whether the insertion is a frameshift
  if($type eq '+') {
    #Reads                substr($allele, 1) ) % 3
    $beginning = (length( substr($_[3], 1) ) % 3 ? $frameshift : $inFrame) . "[";

    # Using an array makes it easier to use a single string building function below.

    #Reads:       [ $dbPosition + 1 ];
    $dbDataAref = [ $_[2] + 1 ];

    #By passing the dbRead function an array, we get an array of data back
    #even if it's one position worth of data
    #Reads:
    #$self->{_db}->dbRead( $chr, $dbDataAref );
    $_[0]->{_db}->dbRead( $_[1], $dbDataAref );

  ###################### If the site is a deletion ######################
  # Deletions are easier to understand; the annotation is the sum of all of the
  # deleted bases. So we take all of the annotaiton
  } elsif($type eq '-') {
    #Reads:       $allele % 3
    $beginning = ($_[3] % 3 ? $frameshift : $inFrame) . "[";
    
    #Get everything including the current dbPosition, in order to simplify code
    #Has a small perf. when there are few indels 
    #Since $allele is a negative number
    #Therefore $dbPosition + $allele == $dbPosition -N bases

    #Reads:       [ $dbPosition + $allele .. $dbPosition ];
    $dbDataAref = [ $_[2] + $_[3] .. $_[2] ];

    # dbRead modifies by reference; each position in dbDataAref gets database data or undef
    # if nothing found
    #Reads:
    #$self->{_db}->dbRead( $chr, $dbDataAref );
    $_[0]->{_db}->dbRead( $_[1], $dbDataAref );
  } else {
    #Reads:
    #$self->log("warn"
    $_[0]->log("warn", "Can't recognize allele $_[3] on $_[1]:@{[$_[2] + 1]}
      as valid indel (must start with - or +)");
    return undef;
  }

  # Will always be an array of dbData, which is to say an array of array presently
  for my $data (@$dbDataAref) {
    #Reads:       $data->[$self->{_dbName}] ) {
    if (! defined $data->[$_[0]->{_dbName}] ) {
      #this position doesn't have a gene track, so skip
      $middle .= "$intergenic,";
      next;
    }
    #Reads:        $siteUnpacker->unpack($data->[$self->{_dbName}]);
    my $siteData = $siteUnpacker->unpack($data->[$_[0]->{_dbName}]);

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
