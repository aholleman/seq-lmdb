use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Build;

our $VERSION = '0.001';

# ABSTRACT: A base class for track classes
# VERSION

use Moose 2;
use Moose::Util::TypeConstraints; 
use namespace::autoclean;
use Path::Tiny;
use MooseX::Types::Path::Tiny qw/AbsPath/;

extends 'Seq::Tracks::Base';

# coming from config file, must contain keys:
# features, name, type
has tracks => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
  required => 1,
);

has trackBuilders =>(
  is => 'ro',
  isa => 'HashRef[ArrayRef]',
  lazy => 1,
  builder => '_buildTrackBuilders',
);

has files_dir   => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1 );

#this only is used by Build
has local_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  lazy    => 1,
  default => sub { [] },
);

has remote_dir => ( is => 'ro', isa => 'Str', lazy => 1, default => '');
has remote_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => { all_remote_files => 'elements', },
  lazy => 1,
  default => sub { [] },
);

has sql_statement => ( is => 'ro', isa => 'Str', lazy => 1, default => '');

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
    my $className = $self->getBuilder($trackHref->{type} );
    if(!$className) {
      $self->tee_logger('warn', "Invalid track type $trackHref->{type}");
      next;
    }
    push @{$out{$trackHref->{type} } }, $className->new($trackHref);
  }
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

#The role of this func is to wrap the data that each individual build method
#creates, in a consistent schema. This should match the way that Seq::Tracks::Base
#retrieves data
#@param $chr: this is a bit of a misnomer
#it is really the name of the database
#for region databases it will be the name of track (name: )
#The role of this func is NOT to decide how to model $data;
#that's the job of the individual builder methods
sub writeFeaturesData {
  #overwrite not currently used
  my ($self, $chr, $pos, $data, $overwrite) = @_;

  #Seq::Tracks::Base should know to retrieve data this way
  #this is our schema
  my %out = (
    $self->name => {
      $self->typeKey => $self->type,
      $self->dataKy => $data,
    }
  );

  $self->dbPatch($chr, $pos, \%out);
}

#@param $posHref : {positionKey : data}
#the positionKey doesn't have to be numerical;
#for instance a gene track may use its gene name
sub writeAllFeaturesData {
  #overwrite not currently used
  my ($self, $chr, $posHref) = @_;

  my $featuresData;

  my %out;

  for my $key (keys %$posHref) {
    $out{$key} = {
      $self->name => {
        $self->typeKey => $self->type,
        $self->dataKy => $posHref->{$key},
      }
    }
  }

  $self->dbPatchBulk($chr, \%out);
}

#all* returns array ref
#we coupled ngene to gene tracks, to allow this
sub allGeneTracks {
  my $self = shift;
  return $self->trackBuilders->{$self->geneType};
}

sub allSnpTracks {
  my $self = shift;
  return $self->trackBuilders->{$self->snpType};
}

sub allRegionTracks {
  my $self = shift;
  return $self->trackBuilders->{$self->regionType};
}

sub allScoreTracks {
  my $self = shift;
  return $self->trackBuilders->{$self->scoreType};
}

sub allSparseTracks {
  my $self = shift;
  return $self->trackBuilders->{$self->sparseType};
}

#returns hashRef; only one of the following tracks is allowed
sub refTrack {
  my $self = shift;
  return $self->trackBuilders->{$self->refType}[0];
}

__PACKAGE__->meta->make_immutable;

1;

# sub updateAllFeaturesData {
#   #overwrite not currently used
#   my ($self, $chr, $pos, $dataHref, $overwrite) = @_;

#   if(!defined $dataHref->{$self->name} 
#   || $dataHref->{$self->name}{type} eq $self->type ) {
#     $self->tee_logger('warn', 'updateAllFeaturesData requires 
#       data of the same type as the calling track object');
#     return;
#   }

#   goto &writeAllFeaturesData;
# }