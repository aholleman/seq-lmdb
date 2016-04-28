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
use Data::Dump qw/ dump /;

extends 'Seq::Tracks::Get';

with 'Seq::Tracks::Region::Definition';
with 'Seq::Role::DBManager';

#In order to get from gene track, we  need to get the values from
#the region track portion as well as from the main database
#we'll cache the region track portion to avoid wasting time
my $geneTrackRegionDataHref;

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
  my $siteDetailsRef = $geneData->{$self->siteFeatureName};
  #first let's get the site details

  if(ref $siteDetailsRef eq 'ARRAY') {
    for my $siteDetail (@$siteDetailsRef) {
      my $siteDetailsHref = $self->unpackCodon($siteDetail);
      for my $key (keys %$siteDetailsHref) {
        if(exists $out{$key} ) {
          push @{ $out{$key} }, $siteDetailsHref;
        }
      }
    }
  } else {
    #put all key => value pairs into %out;
    %out = (%$siteDetailsRef);
  }

  #Now get all of the region stuff
  if(!defined $geneTrackRegionDataHref->{$chr} ) {
    $geneTrackRegionDataHref->{$chr} = $self->dbReadAll( $self->regionTrackPath($chr) );
  }

  my $geneRegionNumberRef = $geneData->{$self->regionReferenceFeatureName};
    
  my %geneData;
  if(ref $geneRegionNumberRef) {
    if(ref $geneRegionNumberRef ne 'ARRAY') {
      $self->log('warn', 'Don\'t know what to do with a gene region db referene 
        that isn\'t a scalar or array');
    } else {
      for my $geneRegionNumber (@$geneRegionNumberRef) {
        %geneData = $geneTrackRegionDataHref->{$geneRegionNumber};
      }
    }
  }
  

  
  #now go from the database feature names to the human readable feature names
  #and include only the featuers specified in the yaml file
  #each $pair <ArrayRef> : [dbName, humanReadableName]
  for my $name ($self->allFeatureNames) {
    #First, we want to get the 
    #reads: $href->{$self->dbName}{ $pair->[0] } where $pair->[0] == feature dbName
    my $val = $geneData->{ $self->getFieldDbName($name) }; 
    if ($val) {
      #pair->[1] == feature name (what the user specified as -feature: name
      $out{ $name } = $val;
    }
  }

  say "at end of get in Gene.pm, we have";
  p %out;
};

#TODO: make this, this is the getter

#The only job of this package is to ovload the base get method, and return
#all the info we have.
#This is different from typical getters, in that we have 2 sources of info
#The site info and the region info
#A user can only specify region features they want

__PACKAGE__->meta->make_immutable;

1;
