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

use Seq::Tracks::ReferenceTrack::Build;
use Seq::Tracks::GeneTrack::Build;
use Seq::Tracks::ScoreTrack::Build;
use Seq::Tracks::SparseTrack::Build;
use Seq::Tracks::SnpTrack::Build;
use Seq::Tracks::RegionTrack::Build;

with 'Seq::Role::Message', 'Seq::Tracks::Definition', 'Seq::Role::DBManager',
  'Seq::Role::ConfigFromFile';

has files_dir => (
  is => 'ro',
  isa => AbsDir,
  coerce => 1,
  required => 1,
);

#we'll make the database_dir if it doesn't exist in the buid step
has database_dir => (
  is => 'ro',
  isa => AbsPath,
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
    $self->refType => 'Seq::Tracks::ReferenceTrack',
    $self->geneType => 'Seq::Tracks::GeneTrack',
    $self->scoreType => 'Seq::Tracks::ScoreTrack',
    $self->sparseType => 'Seq::Tracks::SparseTrack',
    $self->snpType => 'Seq::Tracks::SnpTrack',
    $self->regionType => 'Seq::Tracks::RegionTrack',
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
    $self->refType => 'Seq::Tracks::ReferenceTrack::Build',
    $self->geneType => 'Seq::Tracks::GeneTrack::Build',
    $self->scoreType => 'Seq::Tracks::ScoreTrack::Build',
    $self->sparseType => 'Seq::Tracks::SparseTrack::Build',
    $self->snpType => 'Seq::Tracks::SnpTrack::Build',
    $self->regionType => 'Seq::Tracks::RegionTrack::Build',
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

#qw/allGeneTracks allSnpTracks allRegionTracks allScoreTracks
#  allSparseTracks refTrack ngeneTrack/,
# coming from config file
# expects: {
# typeName : {
#  name: someName (optional),
#  data: {
#   feature1:   
#}  
#}
#}
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
    $self->tee_logger('error', 'database_dir given is not a directory');
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
      $self->tee_logger('warn', "Invalid track type $trackHref->{type}");
      next;
    }
    if(exists $out{$trackHref->{name} } ) {
      $self->tee_logger('warn', "More than one track with the same name 
        exists: $trackHref->{name}. Each track name must be unique
      . Overriding the last object for this name, with the new")
    }
    $out{$trackHref->{name} } = $trackClass->new($trackHref);
    #push @{$out{$trackHref->{type} } }, $trackClass->new($trackHref);
  }
  return \%out;
}

#@param $data: {
# type : {
#  name: someName (optional),
#  data: {
#   feature1:   
#}  
#}
#}
sub getAllDataAsHref {

}
#Not certain if this is needed yet; if it is we should keep track of types
#all* returns array ref
# sub allSnpTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->snpType};
# }

# sub allRegionTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->regionType};
# }

# sub allScoreTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->scoreType};
# }

# sub allSparseTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->sparseType};
# }

# #returns hashRef; only one of the following tracks is allowed
# sub refTrack {
#   my $self = shift;
#   return $self->dataTracks->{$self->refType}[0];
# }

# #we could think about relaxing this constraint.
# #in that case, we should couple ngene and gene tracks as one type
# sub geneTrack {
#   my $self = shift;
#   return $self->dataTracks->{$self->geneType};
# }

#this has been coupled to gene
# sub ngeneTrack {
#   my $self = shift;
#   return $self->dataTracks->{$self->ngeneType}[0];
# }

=method all_genome_chrs

  Returns all of the elements of the @property {ArrayRef<str>} C<genome_chrs>
  as an array (not an array reference).
  $self->all_genome_chrs

=cut



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
# sub insantiateTracks {
#   my ( $self, $href ) = @_;

#   my @out;
#   for my $maybeTrackType (keys %$href) {
#     if(!$trackMap->{$maybeTrackType} ) {
#       $self->tee_logger('warn', "Invalid track type $maybeTrackType");
#       next;
#     }
#     push @out, $trackMap->{$maybeTrackType}->new( data => $href->{$maybeTrackType} );
#   }
# }

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

#different from Seq::Tracks in that we store class instances hashed on track type
#this is to allow us to more easily build tracks of one type in a certain order
sub _buildTrackBuilders {
  my $self = shift;

  my %out;
  for my $trackHref (@{$self->tracks}) {
    my $className = $self->getBuilderTrackClass($trackHref->{type} );
    if(!$className) {
      $self->tee_logger('warn', "Invalid track type $trackHref->{type}");
      next;
    }
    # a bit awkward;
    $trackHref->{files_dir} = $self->files_dir;
    $trackHref->{genome_chrs} = $self->genome_chrs;
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

#all* returns array ref
#we coupled ngene to gene tracks, to allow this
sub allGeneTracksBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->geneType};
}

sub allSnpTracksBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->snpType};
}

sub allRegionTracksBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->regionType};
}

sub allScoreTrackBuilders {
  my $self = shift;
  return $self->trackBuilders->{$self->scoreType};
}

sub allSparseTrackBuilder {
  my $self = shift;
  return $self->trackBuilders->{$self->sparseType};
}

#returns hashRef; only one of the following tracks is allowed
sub refTrackBuilder {
  my $self = shift;
  return $self->trackBuilders->{$self->refType}[0];
}

# sub insantiateRef {
#   my ( $self, $href ) = @_;

#   for my $maybeTrackType (keys %$href) {
#     if($maybeTrackType eq $refType) {
#       return $trackMap->{$refType}->new($href)
#     }
#   }
# }

# sub insantiateSparse {
#   my ( $self, $href ) = @_;

#   my @out;
#   for my $maybeTrackType (keys %$href) {
#     if($maybeTrackType eq $refType) {
#       return $trackMap->{$spareType}->new($href)
#     }
#   }
# }

__PACKAGE__->meta->make_immutable;

1;
