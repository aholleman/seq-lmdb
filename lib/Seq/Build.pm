use 5.10.0;
use strict;
use warnings;

package Seq::Build;

our $VERSION = '0.001';

use DDP;
# ABSTRACT: A class for building all files associated with a genome assembly
# VERSION

=head1 DESCRIPTION

  @class Seq::Build
  #TODO: Check description
  Build the annotation databases, as prescribed by the genome assembly.

  @example

Uses:
=for :list
* @class Seq::Build::SnpTrack
* @class Seq::Build::GeneTrack
* @class Seq::Build::TxTrack
* @class Seq::Build::GenomeSizedTrackStr
* @class Seq::KCManager
* @role Seq::Role::IO

Used in:
=for :list
* /bin/build_genome_assembly.pl

Extended in: None

=cut

use Moose 2;
use namespace::autoclean;
use DDP;
extends 'Seq::Base';


# #this isn't used yet.
# has wanted_chr => (
#   is      => 'ro',
#   isa     => 'Maybe[Str]',
# );

# comes from Seq::Tracks, which is extended by Seq::Assembly
has wantedType => (
  is => 'ro',
  isa => 'Maybe[TrackType]',
  lazy => 1,
  default => undef,
);

#TODO: allow building just one track, identified by name
has wantedName => (
  is => 'ro',
  isa => 'Maybe[Str]',
  lazy => 1,
  default => undef,
);

#Figures out what track type was asked for 
#and then builds that track by calling the tracks 
#"buildTrack" method
sub BUILD {
  my $self = shift;

  my @builders;
  if($self->wantedType) {
    @builders = $self->getTrackBuildersByType($self->wantedType);
  } elsif($self->wantedName) {
    @builders = $self->getTrackBuilderByName($self->wantedName);
  } else {
    @builders = $self->getAllTrackBuilders();
  }

  if($self->debug) {
    say "requested builders are";
    p @builders;
  }
  
  for my $bTypeAref (@builders) {
    for my $builder (@$bTypeAref) {
      $builder->buildTrack();
      $self->log('debug', "finished building " . $builder->name );
    }
  }

  $self->log('debug', "finished building all requested tracks: " 
    . join(@builders, ', ') );
}

__PACKAGE__->meta->make_immutable;

1;
