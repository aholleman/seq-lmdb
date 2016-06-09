use 5.10.0;
use strict;
use warnings;

#### TODO: Could do a better job optimizing for non-multiallelic sites ####
package Seq::Tracks::Gene;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class B<Seq::Gene>
  
  Takes a hash ref (which presumably comes from the database)
  And returns a hash ref with {
    feature1 => value1,
    etc
  }

  Also adds a regionType, siteType, and txEffects key
  
  Handles indels

=cut

use Moose 2;

use Carp qw/ confess /;
use namespace::autoclean;
use DDP;


extends 'Seq::Tracks::Get';

use Seq::Tracks::Gene::Site;
use Seq::Tracks::Gene::Site::SiteTypeMap;
use Seq::Tracks::Gene::Site::CodonMap;

#regionReferenceFeatureName and regionTrackPath
with 'Seq::Tracks::Region::Definition',
#siteFeatureName, defaultUCSCgeneFeatures, nearestGeneFeatureName
'Seq::Tracks::Gene::Definition',
#dbReadAll
'Seq::Role::DBManager';

### objects that get used by multiple subs, but shouldn't be public attributes ###
state $siteUnpacker = Seq::Tracks::Gene::Site->new();
state $siteTypeMap = Seq::Tracks::Gene::Site::SiteTypeMap->new();
state $codonMap = Seq::Tracks::Gene::Site::CodonMap->new();

### Additional "features" that we will add to our output ###
state $refAminoAcidKey = 'referenceAminoAcid';
state $newAminoAcidKey = 'newAminoAcid';
state $regionTypeKey = 'regionType';
state $nearestGeneSubTrackName = 'nearest';
state $siteTypeKey = 'siteType';
state $txEffectsKey = 'txEffect';

### region type possible values ###
state $intergenic = 'Intergenic';
state $intronic = 'Intronic';
state $exonic = 'Exonic';

### txEffect possible values ###
state $silent = 'Silent';
state $replacement = 'Replacement';
state $frameshift = 'Frameshift';
state $inFrame = 'InFrame';
state $startLoss = 'StartLoss';
state $stopLoss = 'StopLoss';
state $truncated = 'TruncatedCodon';

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub{ my $self = shift; return $self->defaultUCSCgeneFeatures; },
);

### Cache self->getFieldDbName calls to save a bit on performance & improve readability ###
state $allCachedDbNames;

#### Add our other "features", everything we find for this site ####
override 'BUILD' => sub {
  my $self = shift;

  $self->addFeaturesToHeader([$siteUnpacker->allSiteKeys, $regionTypeKey,
    $siteTypeKey, $txEffectsKey, $refAminoAcidKey, $newAminoAcidKey], $self->name);

  my @nearestFeatureNames = $self->allNearestFeatureNames;
  
  if(@nearestFeatureNames) {
    $self->addFeaturesToHeader( [ map { "$nearestGeneSubTrackName.$_" } @nearestFeatureNames ], 
      $self->name);
  }

  ###Build up a list of fieldDbNames; these are called millions of times ###
  $allCachedDbNames->{$self->name} = {
    $self->siteFeatureName => $self->getFieldDbName($self->siteFeatureName),
    $self->nearestGeneFeatureName => $self->getFieldDbName($self->nearestGeneFeatureName),
    $self->regionReferenceFeatureName => $self->getFieldDbName($self->regionReferenceFeatureName),
  };

  for my $featureName ($self->allFeatureNames) {
    $allCachedDbNames->{$self->name}->{$featureName} = $self->getFieldDbName($featureName);
  }

  for my $nearestFeatureName ($self->allNearestFeatureNames) {
    $allCachedDbNames->{$self->name}->{$nearestFeatureName} = $self->getFieldDbName($nearestFeatureName);
  }

  super();
};

#gets the gene, nearest gene data for the position
#also checks for indels
#@param <String|ArrayRef> $allelesAref : the alleles (including ref potentially)
# that are found in the user's experiment, for this position that we're annotating
#@param <Number> $dbPosition : The 0-index position of the current data
sub get {
  my ($self, $href, $chr, $dbPosition, $refBase, $allelesAref) = @_;

  #### Get all of the region data if not already fetched
  #we expect the region database to look like
  # {
  #  someNumber => {
  #    $self->name => {
  #     someFeatureDbName1 => val1,
  #     etc  
  #} } }
  state $geneTrackRegionHref = {};
  if(!defined $geneTrackRegionHref->{$self->name}->{$chr} ) {
    $geneTrackRegionHref->{$self->name}->{$chr} = $self->dbReadAll( $self->regionTrackPath($chr) );
  }

  my $regionData = $geneTrackRegionHref->{$self->name}->{$chr};

  # Gene track data stored in the main database, for this position
  my $geneData = $href->{$self->dbName};
  
  # Cached field names to avoid extra $self->dbName overhead, easier to read
  my $cachedDbNames = $allCachedDbNames->{$self->name};

  my %out;

  ################# Populate nearestGeneSubTrackName ##############
  if(!$self->noNearestFeatures) {
    # this is a reference to something stored in the gene tracks' region database
    my $nearestGeneNumber = $geneData->{ $cachedDbNames->{$self->nearestGeneFeatureName} };

    #may not have one at the end of a chromosome
    if($nearestGeneNumber) {
      for my $nFeature ($self->allNearestFeatureNames) {
        $out{"$nearestGeneSubTrackName.$nFeature"} = $regionData->{$nearestGeneNumber}
          ->{$self->dbName}->{ $cachedDbNames->{$nFeature} };
      }
    }
  } 

  ################# Check if this position is in a place covered by gene track #####################
  #a single position may cover one or more sites
  #we expect either a single value (href in this case) or an array of them

  # if $href has
  # {
  #  $self->regionReferenceFeatureName => someNumber
  #}
  #this position covers these genes
  my $geneRegionNumberRef = $geneData->{ $cachedDbNames->{$self->regionReferenceFeatureName} };

  ################# Populate $regionTypeKey if no gene is covered #####################
  if(!$geneRegionNumberRef) {
    $out{$regionTypeKey} = $intergenic;
    return \%out;
  }

  ################# Populate geneTrack's user-defined features #####################
  my $regionDataAref = ref $geneRegionNumberRef ? [ map { $regionData->{$_}->{$self->dbName} } @$geneRegionNumberRef ]
    : [ $regionData->{$geneRegionNumberRef}->{$self->dbName} ];
  
  #now go from the database feature names to the human readable feature names
  #and include only the featuers specified in the yaml file
  #each $pair <ArrayRef> : [dbName, humanReadableName]
  #and if we don't have the feature, that's ok, we'll leave it as undefined
  #also, if no features specified, then just get all of them
  #better too much than too little
  for my $featureName ($self->allFeatureNames) {
    INNER: for my $geneDataHref (@$regionDataAref) {
      push @{ $out{$featureName} }, $geneDataHref->{ $cachedDbNames->{$featureName} };
    }
  }

  my $siteDetailsRef = $geneData->{ $cachedDbNames->{$self->siteFeatureName} };

  ###### save unpacked sites, for use in txEffectsKey population #####
  my @unpackedSites;

  ################## Populate site information ########################
  if( !$siteDetailsRef ) {
    $self->log('warn', "Position $chr:@{[$dbPosition+1]} covered a gene" .
      " but didn't have site info. This is a database build error");
    
    return \%out;
  }

  ################# Populate all $siteUnpacker->allSiteKeys and $retionTypeKey #####################
  if(!ref $siteDetailsRef) {
    $siteDetailsRef = [$siteDetailsRef];
  }

  foreach (@$siteDetailsRef) {
    #update the item in the array, to avoid allocating a new array for the purpose
    my $site = $siteUnpacker->unpackCodon($_);

    for my $key (keys %$site) {
      #### Populate the regionTypeKey, which can be Exonic or Intronic ###
      if($key eq $siteUnpacker->siteTypeKey) {
        if( $siteTypeMap->isExonicSite( $site->{$key} ) ) {
          $out{$regionTypeKey} = $exonic;
        }
      }

      #### Populate refAminoAcidKey; note that for a single site
      ###    we can have only one codon sequence, so not need to set array of them ###
      if(defined $site->{$key} && $key eq $siteUnpacker->codonSequenceKey) {
        push @{ $out{$refAminoAcidKey} }, $codonMap->codon2aa( $site->{$key} );
      }

      #strand and site
      push @{ $out{$key} }, $site->{$key};
    }

    push @unpackedSites, $site; #save for us in txEffects;
  }

  ### If regionTypeKey not defined we didn't find isExonicSite(), so Intronic
  if(! $out{$regionTypeKey} ) {
    $out{$regionTypeKey} = $intronic;
  } 

  ################# Populate $transcriptEffectsKey, $refAminoAcidKey, and $newAminoAcidKey #####################
  ################# We include analysis of indels here, becuase  
  #############  we may want to know how/if they disturb genes  #####################
  my @alleles = ref $allelesAref ? @$allelesAref : ($allelesAref);

  for my $allele (@alleles) {
    my @accum;
    if(length($allele) > 1) {
      my $type = substr($allele, 0, 1);

      #store as array because our output engine writes [ [one], [two] ] as "1,2"
      push @accum, [ $self->_annotateIndel($chr, $dbPosition, $allele) ];

      next;
    }

    ######### Most cases are just snps, so we will inline that functionality #############
    state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };

    # say "number of unpacked codons is: " . scalar @unpackedSites;
    ### We only populate newAminoAcidKey for snps ###
    SNP_LOOP: for (my $i = 0; $i < @unpackedSites; $i++ ) {
      my $refCodonSequence = $unpackedSites[$i]->{ $siteUnpacker->codonSequenceKey };

      if(!$refCodonSequence) {
        push @accum, "Non-Coding";

        next SNP_LOOP;
      }

      if(length($refCodonSequence) != 3) {
        $self->log('warn', "The codon @ $chr: @{[$dbPosition + 1]}" .
          " isn't 3 bases long: $refCodonSequence");
        
        push @accum, $truncated;
        next SNP_LOOP;
      }

      # If codon is on the opposite strand, invert the allele
      if( $unpackedSites[$i]->{ $siteUnpacker->strandKey } eq '-' ) {
        $allele = $negativeStrandTranslation->{$allele};
      }

      #make a codon where the reference base is swapped for the allele
      my $alleleCodonSequence = $refCodonSequence;
      substr($alleleCodonSequence, $unpackedSites[$i]->{ $siteUnpacker->codonPositionKey }, 1 ) = $allele;

      my $newAmino = $codonMap->codon2aa($refCodonSequence);
      push @{ $out{$newAminoAcidKey} }, $newAmino;
      
      # say "allele is $allele, position is $unpackedSites[$i]->{ $siteUnpacker->codonPositionKey }";
      # say "new aa is $refCodonSequence";

      # If reference codon is same as the allele-substititued version, it's a Silent site
      if( $codonMap->codon2aa($refCodonSequence) eq $newAmino ) {
        push @accum, $silent;
      } else {
        push @accum, $replacement;
      }
    }

    if(@accum) {
      push @{ $out{$txEffectsKey} }, @accum > 1 ? \@accum : $accum[0];
    }
  }

  if( !defined $out{$txEffectsKey} ) {
    $out{$txEffectsKey} = $intergenic;
  } elsif( @{ $out{$txEffectsKey} } == 1) {
    $out{$txEffectsKey} = $out{$txEffectsKey}->[0];
  }

  return \%out;
};

sub _annotateIndel {
  my ($self, $chr, $dbPosition, $allele) = @_;

  my $beginning;
  
  my $dbDataAref;
  #### Check if insertion or deletion ###
  if(substr($allele, 0, 1) eq '+') {
    #insetion
    $beginning = (length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame) ."[";

    #by passing the dbRead function an array, we get an array of data back
    #even if it's one position worth of data
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + 1 ] );
  } elsif(substr($allele, 0, 1) eq '-') {
    #deletion
    $beginning = ($allele % 3 ? $frameshift : $inFrame) ."[";
    
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + $allele .. $dbPosition ] );
  } else {
    $self->log("warn", "Can't recognize allele $allele on $chr:@{[$dbPosition + 1]}
      as valid indel (must start with - or +)");
    return undef;
  }

  my $count = 0;
  for my $data (@$dbDataAref) {
    if (! defined $data->{ $self->dbName } ) {
      #this position doesn't have a gene track, so skip
      $beginning .= "$intergenic";
      next;
    }

    if($count++ > 1) {
      #separate different positions by a pipe to denote difference from alleles and
      #transcripts (transcripts separated by a ";")
      substr($beginning, -1, 1) = "|";
    }
      
   

    my $siteData = $data->{ $self->dbName }->{
      $allCachedDbNames->{$self->name}->{$self->siteFeatureName} };

    if(! ref $siteData ) {
      $siteData = [$siteData];
    }

    for my $oneSiteData (@$siteData) {
      my $site = $siteUnpacker->unpackCodon($oneSiteData);

      if ( defined $site->{ $siteUnpacker->codonNumberKey } && $site->{ $siteUnpacker->codonNumberKey } == 1 ) {
        $beginning .= "$startLoss;";
      } elsif ( defined $site->{ $siteUnpacker->codonSequenceKey }
      &&  $codonMap->codon2aa( $site->{ $siteUnpacker->codonSequenceKey } ) eq '*' ) {
        $beginning .= "$stopLoss;";
      } else {
        $beginning .= $site->{ $siteUnpacker->siteTypeKey } . ";";
      }
    }
  }
  
  chop $beginning;
  return "beginning]";
}

__PACKAGE__->meta->make_immutable;

1;
