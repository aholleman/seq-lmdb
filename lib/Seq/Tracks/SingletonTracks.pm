#configures all of the tracks at run time
#allowing any track to be consumed without re-configuring it
#THIS REQUIRES SOME CONSUMING CLASS TO CALL IT, BEFORE ANY OF THE 
#PACKAGES IN Seq::Tracks CAN USE THIS CLASS

# used to simplify process of detecting tracks
# expects structure to be {
#  trackName : {stuff},
#  trackName2 : {stuff},
#}
#so (in db) {
#   trackName : {
#     featureName: featureValue  
#} 

#So this package handles configuring all of the track classes, based on the YAML
#config file that has a property called "tracks"

#We aren't actually configuring one instance of each track and using it ad-naseum
#However, we store the "tracks" argument exactly once
#This allows tracks to call other tracks, without having any insight knowledge
#about which arguments that track requires to be built.

#We typically expect that we don't want to instantiate a new object for each data source
#since we can just do a quick lookup on $self->{trackBuilders}{trackName} for instance
#but this class isn't necesarily incompatible with that mode of use,

#TODO: Add a "instance" method that creates a new instance of a track?

#TODO: Rename this class to something that sounds less like a true singleton
#TODO: make this class more efficient by not building all tracks at once
#all may not be needed.

use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::SingletonTracks;

use Moose 2;
use DDP;

use MooseX::Types::Path::Tiny qw/AbsDir/;
#defines refType, scoreType, etc
with 'Seq::Tracks::Base::Types', 'Seq::Role::Message', 'Seq::Tracks::Headers';

use Seq::Tracks::Reference;
use Seq::Tracks::Score;
use Seq::Tracks::Sparse;
use Seq::Tracks::Region;
use Seq::Tracks::Gene;
use Seq::Tracks::Cadd;

use Seq::Tracks::Reference::Build;
use Seq::Tracks::Score::Build;
use Seq::Tracks::Sparse::Build;
use Seq::Tracks::Region::Build;
use Seq::Tracks::Gene::Build;
use Seq::Tracks::Cadd::Build;

#Public, accessble
state $trackBuilders; 
$trackBuilders = $trackBuilders || {};
has trackBuildersByName => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getTrackBuilderByName => 'get',
    getAllTrackBuilders => 'values',
  },
  lazy => 1,
  init_arg => undef,
  default => sub { $trackBuilders },
  writer => '_writeTrackBuildersByName',
);

state $trackBuildersByType;
$trackBuildersByType = $trackBuildersByType || {};
has trackBuildersByType => (
  is => 'ro',
  isa => 'HashRef[ArrayRef]',
  traits => ['Hash'],
  handles => {
    getTrackBuildersByType => 'get',
  },
  lazy => 1,
  init_arg => undef,
  default => sub{ $trackBuildersByType },
  writer => '_writeTrackBuildersByType',
);

state $trackGetters;
$trackGetters = $trackGetters || {};
has trackGettersByName =>(
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getTrackGetterByName => 'get',
    getAllTrackGetters => 'values'
  },
  init_arg => undef,
  lazy => 1,
  default => sub { $trackGetters },
  writer => '_writeTrackGettersByName'
);

state $trackGettersByType;
$trackGettersByType = $trackGettersByType || {};
has trackGettersByType =>(
  is => 'ro',
  isa => 'HashRef[ArrayRef]',
  traits => ['Hash'],
  handles => {
    getTrackGettersByType => 'get',
  },
  init_arg => undef,
  lazy => 1,
  default => sub { $trackGettersByType },
  writer => '_writeTrackGettersByType'
);

# Only property expected at construction to be passed to this class

# This attr is not required, but must be set the first time this class is used
# it is used
# comes from config file
# this is dictated by the config file structure
# TODO: could make a class that has the properties
# expected in the config file
# expects: {
  # typeName : {
  #  name: someName (optional),
  #  data: {
  #   feature1:   
#} } }

#These are optional attributes after the first consumption of this class
#But the first time, they should be present in order than track instances can be
#made
has tracks => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
  lazy => 1,
  default => sub { [] },
);

#Initialize once, then use forever
sub initializeTrackBuildersAndGetters {
  if(%$trackBuilders && %$trackGetters) {
    return;
  }

  my $self = shift;

  if(! $self->tracks ) {
    $self->log('fatal', 'First time SingletonTracks is run self->tracks must be present');
  }

  if(!%$trackBuilders) {
    $self->_buildTrackBuilders;
  }

  if(!%$trackGetters) {
    $self->_buildTrackGetters;
  }
}

sub BUILD {
  goto &initializeTrackBuildersAndGetters;
}

#like the original as_href this prepares a site for serialization
#instead of introspecting, it uses the features defined in the config
#This defines our schema, e.g how the data is stored in the kv database
# {
#  name (this is the track name) : {
#   type: someType,
#   data: {
#     feature1: featureVal1, feature2: featureVal2, ...
#} } } }

sub allRegionTrackBuilders {
  my $self = shift;
  return $self->trackBuildersByType->{$self->regionType};
}

sub allScoreTrackBuilders {
  my $self = shift;
  return $self->trackBuildersByType->{$self->scoreType};
}

sub allSparseTrackBuilders {
  my $self = shift;
  return $self->trackBuildersByType->{$self->sparseType};
}

sub allGeneTrackBuilders {
  my $self = shift;
  return $self->trackBuildersByType->{$self->geneType};
}

#returns hashRef; only one of the following tracks is allowed
sub getRefTrackBuilder {
  my $self = shift;
  return $self->trackBuildersByType->{$self->refType}[0];
}

#Now same for 
#returns hashRef; only one of the following tracks is allowed
sub getRefTrackGetter {
  my $self = shift;
  return $self->trackGettersByType->{$self->refType}[0];
}

#private builder methods
sub _buildTrackGetters {
  my $self = shift;

  if(%$trackGetters) {
    $self->_writeTrackGettersByName($trackGetters);
    $self->_writeTrackGettersByType($trackGettersByType);
  }

  my @trackOrder;
  for my $trackHref (@{$self->tracks}) {
    #get the trackClass
    my $trackFileName = $self->_toTrackGetterClass($trackHref->{type} );
    #class 
    my $className = $self->_toTrackGetterClass( $trackHref->{type} );

    my $track = $className->new($trackHref);

    if(exists $trackGetters->{$track->{name} } ) {
      $self->log('fatal', "More than one track with the same name 
        exists: $trackHref->{name}. Each track name must be unique
      . Overriding the last object for this name, with the new")
    }

    push @trackOrder, $track->{name};

    #we use the track name rather than the trackHref name
    #because at the moment, users are allowed to rename their tracks
    #by name : 
      #   something : someOtherName
    #TODO: make this go away by automating track name conversion/storing in db
    $trackGetters->{$track->{name} } = $track;
    push @{$trackGettersByType->{$trackHref->{type} } }, $trackGetters->{$track->{name} };
    #push @{$out{$trackHref->{type} } }, $trackClass->new($trackHref);
  }

  $self->_writeTrackGettersByName($trackGetters);
  $self->_writeTrackGettersByType($trackGettersByType);

  $self->orderTrackHeaders(\@trackOrder);
}

#different from Seq::Tracks in that we store class instances hashed on track type
#this is to allow us to more easily build tracks of one type in a certain order
sub _buildTrackBuilders {
  my $self = shift;

  if(%$trackBuilders) {
    $self->_writeTrackGettersByName($trackBuilders);
    $self->_writeTrackGettersByType($trackBuildersByType);
  }

  for my $trackHref (@{$self->tracks}) {
    my $trackFileName = $self->_toTrackBuilderClass($trackHref->{type} );
    #class 
    my $className = $self->_toTrackBuilderClass( $trackHref->{type} );

    my $track = $className->new($trackHref);

    if(exists $trackBuilders->{$track->{name} } ) {
      $self->log('fatal', "More than one track with the same name 
        exists: $trackHref->{name}. Each track name must be unique
      . Overriding the last object for this name, with the new")
    }

    #we use the track name rather than the trackHref name
    #because at the moment, users are allowed to rename their tracks
    #by name : 
      #   something : someOtherName
    #TODO: make this go away by automating track name conversion/storing in db
    $trackBuilders->{$track->{name} } = $track;
    push @{$trackBuildersByType->{$trackHref->{type} } }, $track;
  }
  
  $self->_writeTrackBuildersByName($trackBuilders);
  $self->_writeTrackBuildersByType($trackBuildersByType);
}

sub _toTitleCase {
  my $self = shift;
  my $name = shift;

  return uc( substr($name, 0, 1) ) . substr($name, 1, length($name) - 1);
}

sub _toTrackGetterClass {
  my $self = shift,
  my $type = shift;

  my $classNamePart = $self->_toTitleCase($type);

  return "Seq::Tracks::" . $classNamePart;
}

sub _toTrackBuilderClass{
  my $self = shift,
  my $type = shift;

  my $classNamePart = $self->_toTitleCase($type);

  return "Seq::Tracks::" . $classNamePart ."::Build";
}

__PACKAGE__->meta->make_immutable;
1;