use 5.10.0;
use strict;
use warnings;

package Seq::Build;
use lib './lib';
our $VERSION = '0.001';

use DDP;
# ABSTRACT: A class for building all files associated with a genome assembly
# VERSION

=head1 DESCRIPTION

  @class Seq::Build
  Iterates all of the builders present in the config file
  And executes their buildTrack method
  Also guarantees that the reference track will be built first

  @example

=cut

use Moose 2;
use namespace::autoclean;
use DDP;
extends 'Seq::Base';

use Seq::Tracks;
use Seq::Tracks::Base::Types;
use List::Util qw/first/;

has wantedType => (is => 'ro', isa => 'Maybe[TrackType]', lazy => 1, default => undef);

#TODO: allow building just one track, identified by name
has wantedName => (
  is => 'ro',
  isa => 'Maybe[Str]',
  lazy => 1,
  default => undef,
);

# Tracks configuration hash
has tracks => (is => 'ro', isa => 'HashRef', required => 1);

#Figures out what track type was asked for 
#and then builds that track by calling the tracks 
#"buildTrack" method
sub BUILD {
  my $self = shift;

  my $tracks = Seq::Tracks->new({tracks => $self->tracks});

  my @builders;
  if($self->wantedType) {
    @builders = @{ $tracks->getTrackBuildersByType($self->wantedType) };
  } elsif($self->wantedName) {
    if(! defined(first { $_->name eq $self->wantedName } $tracks->allTrackBulders ) ) {
      $self->log('fatal', "Track name not recognized")
    }
    @builders = ( $tracks->getTrackBuilderByName($self->wantedName) );
  } else {
    @builders = $tracks->allTrackBulders;

    #If we're building all tracks, reference should be first
    if($builders[0]->name ne $tracks->getRefTrackBuilder()->name) {
      $self->log('fatal', "Reference track should be listed first");
    }
  }

  #TODO: return error codes from the rest of the buildTrack methods
  my $count = 0;
  for my $builder (@builders) {
    $self->log('info', "Started building " . $builder->name );
    
    #TODO: implement errors for all tracks
    my ($exitStatus, $errMsg) = $builder->buildTrack();
    
    if(!defined $exitStatus || $exitStatus != 0) {
      $self->log('warn', "Failed to build " . $builder->name);
    }

    $self->log('info', "Finished building " . $builder->name );
  }

  $self->log('info', "finished building all requested tracks: " 
    . join(", ", map{ $_->name } @builders) );
}

__PACKAGE__->meta->make_immutable;

1;
