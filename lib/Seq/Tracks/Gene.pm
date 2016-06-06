use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class B<Seq::Gene>
  
  Takes a hash ref (which presumably comes from the database)
  And returns a hash ref with {
    feature1 => value1,
    etc
  }

=cut

use Moose 2;

use Carp qw/ confess /;
use namespace::autoclean;
use DDP;
use List::Util qw/reduce/;

extends 'Seq::Tracks::Get';

use Seq::Tracks::Gene::Site;
use Seq::Tracks::SingletonTracks;

#regionReferenceFeatureName and regionTrackPath
with 'Seq::Tracks::Region::Definition',
#siteFeatureName, defaultUCSCgeneFeatures, nearestGeneFeatureName
'Seq::Tracks::Gene::Definition',
#dbReadAll
'Seq::Role::DBManager';


state $regionTypes = ['Intergenic', 'Intronic', 'Exonic'];

state $regionTypeKey = 'regionType';
state $nearestGeneSubTrackName = 'nearest';
state $siteTypeKey = 'siteType';
state $transcriptEffectsKey = 'transcriptEffect';

state $siteUnpacker = Seq::Tracks::Gene::Site->new();
state $transcriptEffects = Seq::Tracks::Gene::Site::Effects->new();

# Set the features that we get from the Gene track region database
has '+features' => (
  default => sub{ my $self = shift; return $self->defaultUCSCgeneFeatures; },
);

#### Add our other "features", everything we find for this site ####
override 'BUILD' => sub {
  my $self = shift;

  super();

  $self->addFeaturesToHeader([$siteUnpacker->allSiteKeys, 
    $regionTypeKey, $siteTypeKey, $transcriptEffectsKeys], $self->name);

  my @nearestFeatureNames = $self->allNearestFeatureNames;
  
  if(@nearestFeatureNames) {
    $self->addFeaturesToHeader( [ map { "$nearestGeneSubTrackName.$_" } @nearestFeatureNames ], 
      $self->name);
  }
};

#gets the gene, nearest gene data for the position
#also checks for indels, i
#@param <String|ArrayRef> $allelesAref : the alleles (including ref potentially)
# that are found in the user's experiment, for this position that we're annotating
#@param <Number> $dbPosition : The 0-index position of the current data
#TODO: be careful with state variable use. That means we can only have
#one gene track, but rest of Seq really supports N types
#Can solve this by using a single, name-spaced (on $self->name) data store
sub get {
  my ($self, $href, $chr, $dbPosition, $refBase, $allelesAref) = @_;

  state $nearestFeatureNames = $self->nearest;

  #### Get all of the region data if not already fetched
  #we expect the region database to look like
  # {
  #  someNumber => {
  #    $self->name => {
  #     someFeatureDbName1 => val1,
  #     etc  
  #} } }
  state $geneTrackRegionDataHref = {};
  if(!defined $geneTrackRegionDataHref->{$chr} ) {
    $geneTrackRegionDataHref->{$chr} = $self->dbReadAll( $self->regionTrackPath($chr) );
  }

  # Gene track data stored in the main database, for this position
  my $geneData = $href->{$self->dbName};

  my %out;

  ################# Populate nearestGeneSubTrackName ##############
  if(@$nearestFeatureNames) {
    #get the database name of the nearest gene track
    #but this never changes, so store as static
    #TODO: this is potentially danerous, could have 2 gene tracks, each iwth their own nearest feature
    #under a different name
    state $nearestGeneFeatureDbName = $self->getFieldDbName( $self->nearestGeneFeatureName );

    # this is a reference to something stored in the gene tracks' region database
    my $nearestGeneNumber = $geneData->{$nearestGeneFeatureDbName};

    #may not have one at the end of a chromosome
    if($nearestGeneNumber) {
      
      #get the nearest gene data
      #outputted as "nearest.someFeature" => value if "nearest" is the nearestGeneFeatureName
      for my $nFeature (@$nearestFeatureNames) {
        $out{"$nearestGeneSubTrackName.$nFeature"} = $geneTrackRegionDataHref->{$chr}
          ->{$nearestGeneNumber}->{$self->dbName}->{ $self->getFieldDbName($nFeature) };
      }
      
    }
  } 

  ################# Check if this position is in a place covered by gene track #####################
  #a single position may cover one or more sites
  #we expect either a single value (href in this case) or an array of them
  state $siteFeatureDbName = $self->getFieldDbName($self->siteFeatureName);
  
  my $siteDetailsRef = $geneData->{$siteFeatureDbName};

  # if $href has
  # {
  #  $self->regionReferenceFeatureName => someNumber
  #}
  # that means it is covering a gene, which is stored at someNumber in the region database
  state $regionRefFeatureDbName = $self->getFieldDbName($self->regionReferenceFeatureName);

  #this position covers these genes
  my $geneRegionNumberRef = $geneData->{ $regionRefFeatureDbName };

  ################# Populate $regionTypeKey if no gene is covered #####################
  if(!($siteDetailsRef && $geneRegionNumberRef ) ) {
    #if we don't have a gene at this site, it's Integenic
    #this is the lowest index item
    $out{$regionTypeKey} = $regionTypes->[0];
    
    return \%out;
  } elsif( !$siteDetailsRef || !$geneRegionNumberRef ) {
    $self->log('warn', "Found one part of gene track but not other on $chr");
   
    #if we don't have a gene at this site, it's Integenic
    #this is the lowest index item
    $out{$regionTypeKey} = $regionTypes->[0];
    $out{$siteEffectsKey} = undef;

    return \%out;
  }

  ################# Populate all $siteUnpacker->allSiteKeys #####################
  if(!ref siteDetailsRef) {
    siteDetailsRef = [siteDetailsRef];
  }

  for my $siteDetail (@$siteDetailsRef) {
    my $siteDetailsHref = $siteUnpacker->unpackCodon($siteDetail);

    for my $key (keys %$siteDetailsHref) {
      if(exists $out{$key} ) {
        if(!ref $out{$key} || ref $out{$key} ne 'ARRAY') {
          $out{$key} = [$out{$key}];
        }
        push @{ $out{$key} }, $siteDetailsHref->{$key};
        next;
      }
      $out{$key} = $siteDetailsHref->{$key};
    }
  }
  
  ################# Populate $regionTypeKey if a transcript is covered #####################
  my $siteTypes = $out{$siteUnpacker->siteTypeKey};
  if( !ref $siteTypes ) {
    #if it's a single site, just need to know if it's coding or not
    if( $siteUnpacker->siteTypeMap->isExonicSite( $siteTypes ) ) {
      $out{$regionTypeKey} = $regionTypes->[2];
    } else {
      $out{$regionTypeKey} = $regionTypes->[1];
    }
  } else {
    #if it's an array (many transcripts), then let's check all of our site types
    REGION_FL: for my $siteType (@$siteTypes) {
      if( $siteUnpacker->siteTypeMap->isExonicSite($siteType) ) {
        $out{$regionTypeKey} = $regionTypes->[2];
        last REGION_FL;
      }
    }
    
    if( !$out{$regionTypeKey} ) {
      $out{$regionTypeKey} = $regionTypes->[1];
    }
  }



  ################# Populate $siteEffectsKey #####################
  $out{$transcriptEffectsKey} = $transcriptEffects->get($chr, $dbPosition, $refBase, $allelesAref, $self);

  ################# Populate geneTrack's user-defined features #####################
  my $regionDataAref;
  if(ref $geneRegionNumberRef) {
    $regionDataAref = [ map { $geneTrackRegionDataHref->{$chr}->{$_}->{$self->dbName} }
      @$geneRegionNumberRef ];
  } else {
    $regionDataAref = [ $geneTrackRegionDataHref->{$chr}->{$geneRegionNumberRef}->{$self->dbName} ];
  }
  
  #now go from the database feature names to the human readable feature names
  #and include only the featuers specified in the yaml file
  #each $pair <ArrayRef> : [dbName, humanReadableName]
  #and if we don't have the feature, that's ok, we'll leave it as undefined
  #also, if no features specified, then just get all of them
  #better too much than too little
  for my $featureName ($self->allFeatureNames) {
    INNER: for my $geneDataHref (@$regionDataAref) {
      if(defined $out{$featureName} ) {
        if(!ref $out{$featureName} || ref $out{$featureName} ne 'ARRAY') {
          $out{$featureName} = [ $out{$featureName} ];
        }
        push @{ $out{$featureName} }, $geneDataHref->{ $self->getFieldDbName($featureName) };
        next INNER;
      }
      $out{ $featureName } = $geneDataHref ? 
        $geneDataHref->{ $self->getFieldDbName($featureName) } : undef;
    }
  }

  return \%out;
};

#TODO: make this, this is the getter

#The only job of this package is to ovload the base get method, and return
#all the info we have.
#This is different from typical getters, in that we have 2 sources of info
#The site info and the region info
#A user can only specify region features they want

__PACKAGE__->meta->make_immutable;

1;
