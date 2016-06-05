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
with 'Seq::Tracks::Base::Types', 'Seq::Role::Message';

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

#preserve the order that is given to us in the config file,
#more declarative
state $orderedTrackBuildersAref = [];
sub getAllTrackBuilders {
  return @$orderedTrackBuildersAref;
}

state $trackBuilders = {};
sub getTrackBuilderByName {
  #my ($self, $name) = @_;
  #$_[1] == $name
  return $trackBuilders->{$_[1]};
}

state $trackBuildersByType = {};
sub getTrackBuildersByType {
  #my ($self, $type) = @_;
  #$_[1] == $type
  return $trackBuildersByType->{$_[1]};
}

state $orderedTrackGettersAref = [];
sub getAllTrackGetters {
  return @$orderedTrackGettersAref;
}

state $trackGetters = {};
sub getTrackGetterByName {
  #my ($self, $name) = @_;
  #$_[1] == $name
  return $trackGetters->{$_[1]};
}

state $trackGettersByType = {};
sub getTrackGettersByType {
  # my ($self, $type) = @_;
  # $_[1] == $type
  return $trackGettersByType->{$_[1]};
}

#returns hashRef; only one of the following tracks is allowed
sub getRefTrackGetter {
  my $self = shift;
  return $trackGettersByType->{$self->refType}[0];
}

sub allRegionTrackBuilders {
  my $self = shift;
  return $trackBuildersByType->{$self->regionType};
}

sub allScoreTrackBuilders {
  my $self = shift;
  return $trackBuildersByType->{$self->scoreType};
}

sub allSparseTrackBuilders {
  my $self = shift;
  return $trackBuildersByType->{$self->sparseType};
}

sub allGeneTrackBuilders {
  my $self = shift;
  return $trackBuildersByType->{$self->geneType};
}

#returns hashRef; only one of the following tracks is allowed
sub getRefTrackBuilder {
  my $self = shift;
  return $trackBuildersByType->{$self->refType}[0];
}

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

#Initialize once, then use forever
sub initializeTrackBuildersAndGetters {
  if(%$trackBuilders && %$trackGetters) {
    return;
  }

  my $self = shift;

  if(! $self->tracks ) {
    $self->log('fatal', 'First time SingletonTracks is run tracks must be passed');
  }

  if(!%$trackBuilders) {
    $self->_buildTrackBuilders;
  }

  if(!%$trackGetters) {
    $self->_buildTrackGetters;
  }
}

#private builder methods
sub _buildTrackGetters {
  if(%$trackGetters) {
    return;
  }

  my $self = shift;

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

    #we use the track name rather than the trackHref name
    #because at the moment, users are allowed to rename their tracks
    #by name : 
      #   something : someOtherName
    $trackGetters->{$track->{name} } = $track;
    
    #allows us to preserve order when iterating over all track getters
    push @$orderedTrackGettersAref, $track;

    push @{$trackGettersByType->{$trackHref->{type} } }, $track;
  }
}

#different from Seq::Tracks in that we store class instances hashed on track type
#this is to allow us to more easily build tracks of one type in a certain order
sub _buildTrackBuilders {
  if(%$trackBuilders) {
    return;
  }

  my $self = shift;

  for my $trackHref (@{$self->tracks}) {
    my $trackFileName = $self->_toTrackBuilderClass($trackHref->{type} );
    #class 
    my $className = $self->_toTrackBuilderClass( $trackHref->{type} );

    my $track = $className->new($trackHref);

    #we use the track name rather than the trackHref name
    #because at the moment, users are allowed to rename their tracks
    #by name : 
      #   something : someOtherName
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

    push @$orderedTrackBuildersAref, $track;

    push @{$trackBuildersByType->{$trackHref->{type} } }, $track;
  }
}

### Helper methods for _buildTrackBulders & _buildTrackGetters methods

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