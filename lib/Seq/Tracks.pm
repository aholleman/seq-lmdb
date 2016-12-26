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

package Seq::Tracks;
use 5.10.0;
use strict;
use warnings;
use DDP;

use Mouse 2;
with 'Seq::Role::Message';

use Seq::Headers;

use Seq::Tracks::Reference;
use Seq::Tracks::Score;
use Seq::Tracks::Sparse;
use Seq::Tracks::Gene;
use Seq::Tracks::Cadd;

use Seq::Tracks::Reference::Build;
use Seq::Tracks::Score::Build;
use Seq::Tracks::Sparse::Build;
use Seq::Tracks::Gene::Build;
use Seq::Tracks::Cadd::Build;

use Seq::Tracks::Base::Types;
########################### Configuration ##################################
# This only matters the first time this class is called
# All other calls will ignore this property
has gettersOnly => (is => 'ro', isa => 'Bool', lazy=> 1, default => 0);

# @param <ArrayRef> tracks: track configuration
# Required only for the first run, after that cached, and re-used
# expects: {
  # typeName : {
  #  name: someName (optional),
  #  data: {
  #   feature1:   
#} } }
has tracks => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
);

########################### Public Methods #################################

# @param <ArrayRef> trackBuilders : ordered track builders
state $orderedTrackBuildersAref = [];
has trackBuilders => ( is => 'ro', isa => 'ArrayRef', init_arg => undef, lazy => 1,
  traits => ['Array'], handles => { allTrackBuilders => 'elements' }, 
  default => sub { $orderedTrackBuildersAref } );

state $trackBuildersByName = {};
sub getTrackBuilderByName {
  # my ($self, $name) = @_; #$_[1] == $name
  return $trackBuildersByName->{$_[1]};
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

state $trackGettersByName = {};
sub getTrackGetterByName {
  #my ($self, $name) = @_; #$_[1] == $name
  return $trackGettersByName->{$_[1]};
}

state $trackGettersByType = {};
sub getTrackGettersByType {
  # my ($self, $type) = @_; # $_[1] == $type
  return $trackGettersByType->{$_[1]};
}

################### Individual track getters ##################

my $types = Seq::Tracks::Base::Types->new();

#only 1 refere
sub getRefTrackGetter {
  my $self = shift;
  return $trackGettersByType->{$types->refType}[0];
}

sub allScoreTrackBuilders {
  my $self = shift;
  return $trackBuildersByType->{$types->scoreType};
}

sub allSparseTrackBuilders {
  my $self = shift;
  return $trackBuildersByType->{$types->sparseType};
}

sub allGeneTrackBuilders {
  my $self = shift;
  return $trackBuildersByType->{$types->geneType};
}

#only one ref track allowed, so we return the first
sub getRefTrackBuilder {
  my $self = shift;
  return $trackBuildersByType->{$types->refType}[0];
}

sub BUILD {
  my $self = shift;

  # The goal of this class is to allow one consumer to configure the tracks
  # for the rest of the program
  # i.e Seq.pm passes { tracks => $someTrackConfiguration } and Seq::Tracks::Gene
  # can call  Seq::Tracks::getRefTrackGetter and receive a configured ref track getter

  # However it is important that in long-running parent processes, which may 
  # instantiate this program more than once, we do not re-use old configurations
  # So every time the parent passes a tracks object, we re-configure this class
  if(! $self->tracks && %$trackGettersByName ) {
    return;
  }

  # If this is 1st time we execute initialize, must have tracks configuration
  if(!$self->tracks || !@{$self->tracks} ) {
    $self->log('fatal', 'First time Seq::Tracks is run tracks configuration must be passed');
  }

  # Cache for future calls to Seq::Tracks
  my $tracks = $self->tracks;

  # Each track getter adds its own features to Seq::Headers, which is a singleton
  # Since instantiating Seq::Tracks also instantiates getters at this point
  # We must clear Seq::Headers here to ensure our tracks can properly do this
  Seq::Headers::initialize();

  $self->_buildTrackGetters($tracks);

  if($self->gettersOnly) {
    return;
  }

  $self->_buildTrackBuilders($tracks);
}

################### Private builders #####################
sub _buildTrackGetters {
  my $self = shift;
  my $trackConfigurationAref = shift;

  if(!$trackConfigurationAref) {
    $self->log('fatal', '_buildTrackBuilders requires trackConfiguration object');
  }

  my %seenTrackNames;

  # We may have previously configured this class in a long running process
  # If so, remove the tracks, free the memory
  if(%$trackGettersByName) {
    $trackGettersByName = {};
    $orderedTrackGettersAref = [];
    $trackGettersByType = {};
  }

  for my $trackHref (@$trackConfigurationAref ) {
    #get the trackClass
    my $trackFileName = $self->_toTrackGetterClass($trackHref->{type} );
    #class 
    my $className = $self->_toTrackGetterClass( $trackHref->{type} );

    my $track = $className->new($trackHref);

    if(exists $seenTrackNames{ $track->{name} } ) {
      $self->log('fatal', "More than one track with the same name 
        exists: $trackHref->{name}. Each track name must be unique
      . Overriding the last object for this name, with the new")
    }

    #we use the track name rather than the trackHref name
    #because at the moment, users are allowed to rename their tracks
    #by name : 
      #   something : someOtherName
    $trackGettersByName->{$track->{name} } = $track;
    
    #allows us to preserve order when iterating over all track getters
    push @$orderedTrackGettersAref, $track;

    push @{$trackGettersByType->{$trackHref->{type} } }, $track;
  }
}

#different from Seq::Tracks in that we store class instances hashed on track type
#this is to allow us to more easily build tracks of one type in a certain order
sub _buildTrackBuilders {
  my $self = shift;
  my $trackConfigurationAref = shift;

  if(!$trackConfigurationAref) {
    $self->log('fatal', '_buildTrackBuilders requires trackConfiguration object');
  }

  my %seenTrackNames;

  # We may have previously configured this class in a long running process
  # If so, remove the tracks, free the memory
  if(%$trackBuildersByName) {
    $trackBuildersByName = {};
    $orderedTrackBuildersAref = [];
    $trackBuildersByType = {};
  }

  for my $trackHref (@$trackConfigurationAref) {
    my $trackFileName = $self->_toTrackBuilderClass($trackHref->{type} );
    #class 
    my $className = $self->_toTrackBuilderClass( $trackHref->{type} );

    my $track = $className->new($trackHref);

    #we use the track name rather than the trackHref name
    #because at the moment, users are allowed to rename their tracks
    #by name : 
      #   something : someOtherName
    if(exists $seenTrackNames{ $track->{name} } ) {
      $self->log('fatal', "More than one track with the same name 
        exists: $trackHref->{name}. Each track name must be unique
      . Overriding the last object for this name, with the new")
    }

    #we use the track name rather than the trackHref name
    #because at the moment, users are allowed to rename their tracks
    #by name : 
      #   something : someOtherName
    #TODO: make this go away by automating track name conversion/storing in db
    $trackBuildersByName->{$track->{name} } = $track;

    push @{$orderedTrackBuildersAref}, $track;

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

######### Alternative way of storing the singleton configuration, by assembly #####

# ########################### Configuration ##################################
# # This only matters the first time this class is called
# # All other calls will ignore this property
# has gettersOnly => (is => 'ro', isa => 'Bool', lazy=> 1, default => 0);

# # @param <Str> assembly : The name of the genome assembly; used to identify
# # which tracks the callee has configured
# state $assembly;

# # @param <ArrayRef> tracks: track configuration
# # Required only for the first run, after that cached, and re-used
# # Expects an array of track key/values that are understood by Seq::Tracks::Base
# # and Seq::Tracks::Build, as well as any children of those classes
# has tracks => (
#   is => 'ro',
#   isa => 'ArrayRef[HashRef]',
# );

# ########################### Public Methods #################################

# # @param <ArrayRef> trackBuilders : ordered track builders
# # {
# #   assembly => [Seq::Tracks::*,Seq::Tracks::*]
# # }
# state $orderedTrackBuilders = {};
# has trackBuilders => ( is => 'ro', isa => 'ArrayRef', init_arg => undef, lazy => 1,
#   traits => ['Array'], handles => { allTrackBulders => 'elements' }, 
#   default => sub { $orderedTrackBuilders->{$assembly} } );

# # @param <HashRef> $trackBuildersByName : track builders stored on name
# # {
# #   assembly => { name => Seq::Tracks::*::Build }
# # }
# state $trackBuildersByName = {};
# sub getTrackBuilderByName {
#   # my ($self, $name) = @_; #$_[1] == $name
#   return $trackBuildersByName->{$assembly}{$_[1]};
# }

# # @param <HashRef> $trackBuildersByType : track builders stored on type
# # {
# #   assembly => { type => Seq::Tracks::*::Build }
# # }
# state $trackBuildersByType = {};
# sub getTrackBuildersByType {
#   #my ($self, $type) = @_; #$_[1] == $type
#   return $trackBuildersByType->{$assembly}{$_[1]};
# }

# # @param <ArrayRef> trackGetters : ordered track getters
# state $orderedTrackGetters = {};

# # @param <ArrayRef> trackGetters : ordered track getters
# has trackGetters => ( is => 'ro', isa => 'ArrayRef', init_arg => undef, lazy => 1,
#   traits => ['Array'], handles => { allTrackGetters => 'elements' } , 
#   default => sub { $orderedTrackGetters->{$assembly} } );

# state $trackGettersByName = {};
# sub getTrackGetterByName {
#   #my ($self, $name) = @_; #$_[1] == $name
#   return $trackGettersByName->{$assembly}{$_[1]};
# }

# state $trackGettersByType = {};
# sub getTrackGettersByType {
#   # my ($self, $type) = @_; # $_[1] == $type
#   return $trackGettersByType->{$assembly}{$_[1]};
# }

# ################### Individual track getters ##################

# my $types = Seq::Tracks::Base::Types->new();

# #only 1 refere
# sub getRefTrackGetter {
#   #my $self = shift;
#   return $trackGettersByType->{$assembly}{$types->refType}[0];
# }

# sub allScoreTrackBuilders {
#  # my $self = shift;
#   return $trackBuildersByType->{$assembly}{$types->scoreType};
# }

# sub allSparseTrackBuilders {
#  # my $self = shift;
#   return $trackBuildersByType->{$assembly}{$types->sparseType};
# }

# sub allGeneTrackBuilders {
# #  my $self = shift;
#   return $trackBuildersByType->{$assembly}{$types->geneType};
# }

# #only one ref track allowed, so we return the first
# sub getRefTrackBuilder {
#   #my $self = shift;
#   return $trackBuildersByType->{$assembly}{$types->refType}[0];
# }

# sub BUILD {
#   my $self = shift;
#   # If $self->gettersOnly set the first time this track is called, all future
#   # invocations will only have getters
#   # This allows us to safely avoid locks, properly treating that as a singleton

#   # $trackGetters is always set upon the first invocation, so it is a reliable
#   # marker of previous initialization
#   # Note that if $self->gettersOnly set, all future invocations cannot get
#   # builders
#   if(!$assembly && !$self->assembly) {
#     $self->log('fatal', 'First tiem Seq::Tracks is run, assembly must be provided');
#   }

#   $assembly = $self->assembly;

#   if(defined $trackGettersByName->{$assembly} &&
#   %{ $trackGettersByName->{$assembly} } ) { 
#     return;
#   }

#   # If this is 1st time we execute initialize, must have tracks configuration
#   if(! @{$self->tracks} ) {
#     $self->log('fatal', 'First time Seq::Tracks is run tracks configuration must be passed');
#   }

#   $self->_buildTrackGetters;

#   if($self->gettersOnly) {
#     return;
#   }

#   if(!defined $trackBuildersByName->{$assembly} && %{ $trackBuildersByName->{$assembly} }) {
#     $self->_buildTrackBuilders;
#   }
# }

# ################### Private builders #####################
# sub _buildTrackGetters {
#   my $self = shift;

#   for my $trackHref (@{$self->tracks}) {
#     #get the trackClass
#     my $trackFileName = $self->_toTrackGetterClass($trackHref->{type} );
#     #class 
#     my $className = $self->_toTrackGetterClass( $trackHref->{type} );

#     my $track = $className->new($trackHref);

#     if(exists $trackGettersByName->{$assembly}{$track->{name} } ) {
#       $self->log('fatal', "More than one track with the same name 
#         exists: $trackHref->{name}. Each track name must be unique
#       . Overriding the last object for this name, with the new")
#     }

#     #we use the track name rather than the trackHref name
#     #because at the moment, users are allowed to rename their tracks
#     #by name : 
#       #   something : someOtherName
#     $trackGettersByName->{$assembly}{$track->{name} } = $track;
    
#     #allows us to preserve order when iterating over all track getters
#     push @{ $orderedTrackGetters->{$assembly} }, $track;

#     push @{$trackGettersByType->{$assembly}{$trackHref->{type} } }, $track;
#   }
# }

# #different from Seq::Tracks in that we store class instances hashed on track type
# #this is to allow us to more easily build tracks of one type in a certain order
# sub _buildTrackBuilders {
#   my $self = shift;

#   for my $trackHref (@{$self->tracks}) {
#     my $trackFileName = $self->_toTrackBuilderClass($trackHref->{type} );
#     #class 
#     my $className = $self->_toTrackBuilderClass( $trackHref->{type} );

#     my $track = $className->new($trackHref);

#     #we use the track name rather than the trackHref name
#     #because at the moment, users are allowed to rename their tracks
#     #by name : 
#       #   something : someOtherName
#     if(exists $trackBuildersByName->{$assembly}{$track->{name} } ) {
#       $self->log('fatal', "More than one track with the same name 
#         exists: $trackHref->{name}. Each track name must be unique
#       . Overriding the last object for this name, with the new")
#     }

#     #we use the track name rather than the trackHref name
#     #because at the moment, users are allowed to rename their tracks
#     #by name : 
#       #   something : someOtherName
#     #TODO: make this go away by automating track name conversion/storing in db
#     $trackBuildersByName->{$assembly}{$track->{name} } = $track;

#     push @{ $orderedTrackBuilders->{$assembly} }, $track;

#     push @{$trackBuildersByType->{$assembly}{$trackHref->{type} } }, $track;
#   }
# }