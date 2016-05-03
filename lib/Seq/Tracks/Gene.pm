use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene;

our $VERSION = '0.001';

# ABSTRACT: Class for creating particular sites for a given gene / transcript
# This track is a lot like a region track
# The differences:
# We will bulk load all of its region database into a hash
# {
#   geneID or 0-N position : {
#       features
#}  
#}
# (We could also use a number as a key, using geneID would save space
# as we avoid needing 1 key : value pair
# and gain some meaningful information in the key
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Gene>
  #TODO: Check description

  @example

Used in:
=for :list
* Seq::Build::GeneTrack
    Which is used in Seq::Build
* Seq::Build::TxTrack
    Which is used in Seq::Build

Extended by: None

=cut

use Moose 2;

use Carp qw/ confess /;
use namespace::autoclean;
use DDP;
use List::Util qw/reduce/;

extends 'Seq::Tracks::Get';

use Seq::Tracks::Gene::Site;
#regionReferenceFeatureName and regionTrackPath
with 'Seq::Tracks::Region::Definition',
#siteFeatureName
'Seq::Tracks::Gene::Definition',
#site feature keys
'Seq::Tracks::Gene::Site::SiteKeys',
#dbReadAll
'Seq::Role::DBManager';

#This get class adds a small but crucial bit of info
#Whether a position is Intergenic, Intronic, Exonic
#This used to be held in Seq::Annotate
#But site_type, var_type would case confusion
#I think it's easier to understand if that is here
#And more atomic
#Because the designation for regionType (var_type previously)
#Completely depends on the gene track, and essentially nothing else
#other than assembly, which every track depends on
#so I would rather see, "refSeq.regionType" than 'var_type', because I am 
#more likely to guess what that means
state $regionTypes = ['Intergenic', 'Intronic', 'Exonic'];
state $regionTypeKey = 'regionType';

#these are really the "region database" features
has '+features' => (
  default => sub{ my $self = shift; return $self->defaultUCSCgeneFeatures; },
);

override 'BUILD' => sub {
  my $self = shift;

  super();

  $self->addFeaturesToTrackHeaders([$self->allSiteKeys, $regionTypeKey], $self->name);
};

#In order to get from gene track, we  need to get the values from
#the region track portion as well as from the main database
#we'll cache the region track portion to avoid wasting time
my $geneTrackRegionDataHref;

my $codonUnpacker = Seq::Tracks::Gene::Site->new();

#we simply replace the get method from Seq::Tracks:Get
#because we also need to get ther region portion
#TODO: when we implement region tracks just override their method
#and call super() for the $self->allFeatureNames portion
sub get {
  my ($self, $href, $chr) = @_;

  if(ref $href eq 'ARRAY') {
    goto &getBulk; #should just jump to the inherited getBulk method
  }

  #this is what we have at a site in the main db
  my $geneData = $href->{$self->dbName};

  my %out;

  #a single position may cover one or more sites
  #we expect either a single value (href in this case) or an array of them
  my $siteDetailsRef = $geneData->{$self->getFieldDbName($self->siteFeatureName) };
  my $geneRegionNumberRef = $geneData->{ $self->getFieldDbName($self->regionReferenceFeatureName) };

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
    return \%out;
  }

  #first let's get the site details
  if(!ref $siteDetailsRef) {
    $siteDetailsRef = [$siteDetailsRef];
  }

  if (!ref $siteDetailsRef eq 'ARRAY') {
    $self->log('fatal', 'site details expected to be number or array, got ' .
      ref $siteDetailsRef);
  }

  for my $siteDetail (@$siteDetailsRef) {
    my $siteDetailsHref = $codonUnpacker->unpackCodon($siteDetail);

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
  
  #Now check if it's Exonic, Intronic, or Intergenice
  #If we ever see a coding site, that is exonic
  if( !ref $out{$self->siteTypeKey} ) {
    #if it's a single site, just need to know if it's coding or not
    if( $codonUnpacker->isExonicSite( $out{$self->siteTypeKey} ) ) {
      $out{$regionTypeKey} = $regionTypes->[2];
    } else {
      $out{$regionTypeKey} = $regionTypes->[1];
    }
  } else {
    #if it's an array, then let's check all of our site types
    REGION_FL: foreach(@{ $out{$self->siteTypeKey}  } ) {
      if( $codonUnpacker->isExonicSite($_) ) {
        $out{$regionTypeKey} = $regionTypes->[2];
        last REGION_FL;
      }
    }
    $out{$regionTypeKey} = $regionTypes->[1];
  }

  #Now get all of the region stuff
  if(!defined $geneTrackRegionDataHref->{$chr} ) {
    $geneTrackRegionDataHref->{$chr} = $self->dbReadAll( $self->regionTrackPath($chr) );
  }

  #we expect either a single number or an array ref
  if (!ref $geneRegionNumberRef) {
    $geneRegionNumberRef = [$geneRegionNumberRef];
  }

  if (ref $geneRegionNumberRef ne 'ARRAY') {
    $self->log('fatal', 'gene region number expected to be number or array, got ' .
      ref $geneRegionNumberRef);
  }

  #will die if there was a different ref passed
  my @geneData;
  
  for my $geneRegionNumber (@$geneRegionNumberRef) {
    push @geneData, $geneTrackRegionDataHref->{$chr}->{$geneRegionNumber}->{$self->dbName};
  }
  
  #now go from the database feature names to the human readable feature names
  #and include only the featuers specified in the yaml file
  #each $pair <ArrayRef> : [dbName, humanReadableName]
  #and if we don't have the feature, that's ok, we'll leave it as undefined
  #also, if no features specified, then just get all of them
  #better too much than too little
  for my $featureName ($self->allFeatureNames) {
    INNER: for my $geneDataHref (@geneData) {
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
