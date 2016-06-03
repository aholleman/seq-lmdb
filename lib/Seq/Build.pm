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

use MCE::Loop;

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

has buildClean => (
  is => 'ro',
  isa => 'Bool',
  lazy => 1,
  default => 0,
);

#Figures out what track type was asked for 
#and then builds that track by calling the tracks 
#"buildTrack" method
sub BUILD {

  #$_[0] == $self
  if($_[0]->buildClean) {
    goto &BUILD_CLEAN;
  }

  my $self = shift;

  my @builders;
  if($self->wantedType) {
    @builders = @{ $self->getTrackBuildersByType($self->wantedType) };
  } elsif($self->wantedName) {
    @builders = ( $self->getTrackBuilderByName($self->wantedName) );
  } else {
    @builders = $self->getAllTrackBuilders();
  }

  my @chrs = $builders[0]->allWantedChrs;

  if($self->debug) {
    say "requested builders are";
    p @builders;
  }

  my $refTrackBuilder = $self->getRefTrackBuilder();

  $self->log('info', "Verifying that needed reference tracks are built");

  $refTrackBuilder->buildTrack();
    
  $self->log('info', "Finished building the requisite reference tracks");
    
  #TODO: check whether ref built, and if not, build it, since many packages
  #may need it
  for my $builder (@builders) {
    #we already built the refTrackBuilder
    #could also just check for reference equality,
    #but this is more robust if we end up not using singletons at some point
    #all track names must be unique as a global requirement, so this is safe
    #and of course if the user requests we overwrite, lets respect that
    #but I've for now decided to encapsulate the overwrite check within the 
    #reference track build method
    if($builder->name eq $refTrackBuilder->name) {
      next;
    }

    $self->log('info', "started building " . $builder->name );
   
    $builder->buildTrack();
    
    $self->log('info', "finished building " . $builder->name );
  }

  $self->log('info', "finished building all requested tracks: " 
    . join(", ", map{ $_->name } @builders) );
}

# for now this only works on regular databases, not meta databases
# this works in a simple, mildly silly way for now
# if a chromosome is specified, it will copy that database
# then, it also tries to completely overwrite any gene and region type tracks
# because references to those could have been included in the main database
# being copied
sub BUILD_CLEAN {
  my $self = shift;

  my @builders;

  my $refTrackBuilder = $self->getRefTrackBuilder();

  #use the refTrackBuilder, which is the only required track
  #to figure out which chromosomes are wanted
  my @chrs = $refTrackBuilder->allWantedChrs;
  undef $refTrackBuilder;

  my @regionTracks = $self->allRegionTrackBuilders();

  my @geneTracks = $self->allGeneTrackBuilders();

  MCE::Loop::init {
    max_workers => 26, chunk_size => 1
  };

  #first build clean copies of all wanted chrs
  mce_loop {
    my ($mce, $chunk_ref, $chunk_id) = @_;
    MCE->say("Writing clean database copy of $_");
    $self->dbWriteCleanCopy($_);
  } @chrs;

  if(@regionTracks) {
    mce_loop {
      my ($mce, $chunk_ref, $chunk_id) = @_;
      MCE->say("Writing clean database copy of " . $_->name);
      $self->dbWriteCleanCopy($_->name);
    } @regionTracks;
  }

  if(@geneTracks) {
    mce_loop {
      my ($mce, $chunk_ref, $chunk_id) = @_;
      MCE->say("Writing clean database copy of " . $_->name);
      $self->dbWriteCleanCopy($_->name);
    } @geneTracks;
  }
}

__PACKAGE__->meta->make_immutable;

1;
