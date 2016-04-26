use 5.10.0;
use strict;
use warnings;
our $VERSION = '0.002';

package Seq::Tracks;

# ABSTRACT: A base class for track classes
# VERSION

use Moose 2;
use namespace::autoclean;
use DDP;
use MooseX::Types::Path::Tiny qw/AbsPath AbsDir/;

use Seq::Tracks::Reference;
use Seq::Tracks::Score;
use Seq::Tracks::Sparse;
use Seq::Tracks::Region;
use Seq::Tracks::Gene;

use Seq::Tracks::Reference::Build;
use Seq::Tracks::Score::Build;
use Seq::Tracks::Sparse::Build;
use Seq::Tracks::Region::Build;
use Seq::Tracks::Gene::Build;

with 'Seq::Role::ConfigFromFile', 'Seq::Role::DBManager',
#defines refType, scoreType, etc
'Seq::Tracks::Base::Types';

use DDP;
#expect that this exists, since this is where any local files are supposed
#to be kept
has files_dir => (
  is => 'ro',
  isa => AbsDir,
  coerce => 1,
  required => 1,
);

has trackMap => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getDataTrackClass => 'get',
  },
  init_arg => undef,
  builder => '_buildTrackMap',
  lazy => 1,
);

sub _buildTrackMap {
  my $self = shift;

  return {
    $self->refType => 'Seq::Tracks::Reference',
    $self->scoreType => 'Seq::Tracks::Score',
    $self->sparseType => 'Seq::Tracks::Sparse',
    $self->regionType => 'Seq::Tracks::Region',
    $self->geneType => 'Seq::Tracks::Gene',
  }
};

has builderMap => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getBuilderTrackClass => 'get',
  },
  init_arg => undef,
  builder => '_buildTrackBuilderMap',
  lazy => 1,
);

sub _buildTrackBuilderMap {
  my $self = shift;

  return {
    $self->refType => 'Seq::Tracks::Reference::Build',
    $self->scoreType => 'Seq::Tracks::Score::Build',
    $self->sparseType => 'Seq::Tracks::Sparse::Build',
    $self->regionType => 'Seq::Tracks::Region::Build',
    $self->geneType => 'Seq::Tracks::Gene::Build',
  }
};

=property @public @required {Str} name

  The track name. This is defined directly in the input config file.

  @example:
  =for :list
  * gene
  * snp

=cut
has trackBuilders =>(
  is => 'ro',
  isa => 'HashRef',
  lazy => 1,
  builder => '_buildTrackBuilders',
  traits => ['Hash'],
  handles => {
    getBuilders => 'get',
    getAllBuilders => 'values',
  }
);


has dataTracks =>(
  is => 'ro',
  #isa => 'HashRef[ArrayRef]',
  lazy => 1,
  builder => '_buildDataTracks',
  traits => ['Hash'],
  handles => {
    getDataTracks => 'get',
  }
);

# comes from config file
# expects: {
  # typeName : {
  #  name: someName (optional),
  #  data: {
  #   feature1:   
#} } }
has tracks => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
  required => 1,
);

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

sub BUILD {
  my $self = shift;

  if(!$self->database_dir->exists) {
    say "database dir doesnt exist";
    $self->database_dir->mkpath;
  } elsif (!$self->database_dir->is_dir) {
    return $self->log('error', 'database_dir given is not a directory');
  }
  
  #needs to be initialized before dbmanager can be used
  $self->setDbPath( $self->database_dir );
}

sub _buildDataTracks {
  my $self = shift;

  my %out;
  for my $trackHref (@{$self->tracks}) {
    my $trackClass = $self->getDataTrackClass($trackHref->{type} );
    if(!$trackClass) {
      $self->log('warn', "Invalid track type $trackHref->{type}");
      next;
    }
    if(exists $out{$trackHref->{name} } ) {
      $self->log('error', "More than one track with the same name 
        exists: $trackHref->{name}. Each track name must be unique
      . Overriding the last object for this name, with the new")
    }
    $out{$trackHref->{name} } = $trackClass->new($trackHref);
    #push @{$out{$trackHref->{type} } }, $trackClass->new($trackHref);
  }
  return \%out;
}

#different from Seq::Tracks in that we store class instances hashed on track type
#this is to allow us to more easily build tracks of one type in a certain order
sub _buildTrackBuilders {
  my $self = shift;

  my %out;
  for my $trackHref (@{$self->tracks}) {
    p %$trackHref;
    my $className = $self->getBuilderTrackClass($trackHref->{type} );
    if(!$className) {
      $self->log('warn', "Invalid track type $trackHref->{type}");
      next;
    }
    # a bit awkward;
    $trackHref->{files_dir} = $self->files_dir;
    $trackHref->{genome_chrs} = $self->genome_chrs;
    $trackHref->{overwrite} = $self->overwrite;

    say "about to new $className";
    p $trackHref;
    
    push @{$out{$trackHref->{type} } }, $className->new($trackHref);
  }

  return \%out;
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

sub allRegionTracksBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->regionType};
}

sub allScoreTrackBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->scoreType};
}

sub allSparseTrackBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->sparseType};
}

sub allGeneTrackBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->geneType};
}

#returns hashRef; only one of the following tracks is allowed
sub refTrackBuilder {
  my $self = shift;
  return $self->trackBuilders->{$self->refType}[0];
}

__PACKAGE__->meta->make_immutable;

1;
