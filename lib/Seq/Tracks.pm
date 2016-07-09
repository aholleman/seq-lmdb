# ABSTRACT: A base class for track classes

# used to simplify process of detecting tracks
# I think that Tracks.pm should know which features it has access to
# and anything conforming to that interface should become an instance
# of the appropriate class
# and everythign else shouldn't, and should generate a warning
# This is heavily inspired by Dr. Thomas Wingo's primer picking software design
# expects structure to be {
#  trackName : {typeStuff},
#  typeName2 : {typeStuff2},
#}

#We don't instantiate a new object for each data source
#Instead, we simply create a container for each name : type pair
#We could use an array, but a hash is easier to reason about
#We also expect that each record will be identified by its track name
#so (in db) {
#   trackName : {
#     featureName: featureValue  
#} 
#}

use 5.10.0;
use strict;
use warnings;

package Seq::Tracks;

use Mouse 2;
#defines refType, scoreType, etc
with 'Seq::Tracks::Base::Types',
'Seq::Role::Message';

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

########################### Configuration ##################################
has gettersOnly => (is => 'ro', isa => 'Bool', lazy=> 1, default => 0);

# @param <ArrayRef> tracks: track configuration
# Required only for the first run, after that cached, and re-used
# expects: {
  # typeName : {
  #  name: someName (optional),
  #  data: {
  #   feature1:   
#} } }
state $tracks = [];
has tracks => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
  lazy => 1,
  default => sub { $tracks },
);

########################### Public Methods #################################

# @param <ArrayRef> trackBuilders : ordered track builders
state $orderedTrackBuildersAref = [];
has trackBuilders => ( is => 'ro', isa => 'ArrayRef', init_arg => undef, lazy => 1,
  traits => ['Array'], handles => { allTrackBulders => 'elements' }, 
  default => sub { $orderedTrackBuildersAref } );

state $trackBuilders = {};
sub getTrackBuilderByName {
  # my ($self, $name) = @_; #$_[1] == $name
  return $trackBuilders->{$_[1]};
}

state $trackBuildersByType = {};
sub getTrackBuildersByType {
  #my ($self, $type) = @_; #$_[1] == $type
  return $trackBuildersByType->{$_[1]};
}

# @param <ArrayRef> trackGetters : ordered track getters
state $orderedTrackGettersAref = [];
has trackGetters => ( is => 'ro', isa => 'ArrayRef', init_arg => undef, lazy => 1,
  traits => ['Array'], handles => { allTrackGetters => 'elements' } , 
  default => sub { $orderedTrackGettersAref } );

state $trackGetters = {};
sub getTrackGetterByName {
  #my ($self, $name) = @_; #$_[1] == $name
  return $trackGetters->{$_[1]};
}

state $trackGettersByType = {};
sub getTrackGettersByType {
  # my ($self, $type) = @_; # $_[1] == $type
  return $trackGettersByType->{$_[1]};
}

################### Individual track getters ##################

#only 1 refere
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

#only one ref track allowed, so we return the first
sub getRefTrackBuilder {
  my $self = shift;
  return $trackBuildersByType->{$self->refType}[0];
}

sub BUILD {
  my $self = shift;

  if(%$trackGetters && $self->gettersOnly) {
    return;
  }

  if(%$trackBuilders && %$trackGetters) {
    return;
  }

  # If this is 1st time we execute initialize, must have tracks configuration
  if(! @{$self->tracks} ) {
    $self->log('fatal', 'First time Seq::Tracks is run tracks configuration must be passed');
  }

  # Cache for future calls to Seq::Tracks
  $tracks = $self->tracks;

  if(!%$trackGetters) {
    $self->_buildTrackGetters;
  }

  if($self->gettersOnly) {
    return;
  }

  if(!%$trackBuilders) {
    $self->_buildTrackBuilders;
  }
}

################### Private builders #####################
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

####### Helper methods for _buildTrackBulders & _buildTrackGetters methods ########

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