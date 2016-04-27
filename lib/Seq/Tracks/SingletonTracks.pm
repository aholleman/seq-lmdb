#configures all of the tracks at run time
#allowing any track to be consumed without re-configuring it
#THIS REQUIRES SOME CONSUMING CLASS TO CALL IT, BEFORE ANY OF THE 
#PACKAGES IN Seq::Tracks CAN USE THIS CLASS
use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::SingletonTracks;

use Moose::Role;
use DDP;

#defines refType, scoreType, etc
with 'Seq::Tracks::Base::Types', 'Seq::Role::Message';

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

after BUILDARGS => sub {
  say 'HELLLLLOOOO WORLD';
};

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
state $trackBuilders;
has trackBuilders =>(
  is => 'ro',
  isa => 'HashRef',
  lazy => 1,
  init_arg => undef,
  builder => '_buildTrackBuilders',
  traits => ['Hash'],
  handles => {
    getBuilders => 'get',
    getAllBuilders => 'values',
  }
);

state $trackGetters;
has trackGetters =>(
  is => 'ro',
  isa => 'HashRef[ArrayRef]',
  traits => ['Hash'],
  handles => {
    getTrackGetter => 'get',
  },
  init_arg => undef,
  lazy => 1,
  builder => '_buildDataTracks',
);

sub _buildDataTracks {
  if($trackGetters) {
    return $trackGetters;
  }

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
  $trackGetters = \%out;
  return $trackGetters;
}

#different from Seq::Tracks in that we store class instances hashed on track type
#this is to allow us to more easily build tracks of one type in a certain order
sub _buildTrackBuilders {
  if($trackBuilders) {
    return $trackBuilders;
  }

  my $self = shift;

  my %out;
  for my $trackHref (@{$self->tracks}) {
    my $className = $self->getBuilderTrackClass($trackHref->{type} );
    if(!$className) {
      $self->log('warn', "Invalid track type $trackHref->{type}");
      next;
    }
    # a bit awkward;
    $trackHref->{files_dir} = $self->files_dir;
    $trackHref->{genome_chrs} = $self->genome_chrs;
    $trackHref->{overwrite} = $self->overwrite;
    
    push @{$out{$trackHref->{type} } }, $className->new($trackHref);
  }

  $trackBuilders = \%out;
  return $trackBuilders;
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
sub getRefTrackBuilder {
  my $self = shift;
  return $self->trackBuilders->{$self->refType}[0];
}

#Now same for 
#returns hashRef; only one of the following tracks is allowed
sub getRefTrackGetter {
  my $self = shift;
  return $self->trackGetters->{$self->refType}[0];
}

no Moose::Role;
1;