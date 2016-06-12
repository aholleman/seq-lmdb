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
  Iterates all of the builders present in the config file
  And executes their buildTrack method
  Also guarantees that the reference track will be built first

  @example

=cut

use Moose 2;
use namespace::autoclean;
use DDP;
extends 'Seq::Tracks';

#use MCE::Loop;

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

#not in use atm
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
  my $self = shift;

  my @builders;
  if($self->wantedType) {
    @builders = @{ $self->singletonTracks->getTrackBuildersByType($self->wantedType) };
  } elsif($self->wantedName) {
    @builders = ( $self->singletonTracks->getTrackBuilderByName($self->wantedName) );
  } else {
    @builders = $self->singletonTracks->allTrackBulders;
  }

  my @chrs = $builders[0]->allWantedChrs;

  if($self->debug) {
    say "requested builders are";
    p @builders;
  }

      
  #TODO: return error codes from the rest of the buildTrack methods
  for my $builder (@builders) {
    #we already built the refTrackBuilder
    #could also just check for reference equality,
    #but this is more robust if we end up not using singletons at some point
    #all track names must be unique as a global requirement, so this is safe
    #and of course if the user requests we overwrite, lets respect that
    #but I've for now decided to encapsulate the overwrite check within the 
    #reference track build method

    $self->log('info', "Started building " . $builder->name );
    
    #TODO: implement errors for all tracks
    my $err = $builder->buildTrack();
    
    if($err) {
      $self->log('warn', "Failed to build " . $builder->name . " because of $err");
    }

    $self->log('info', "Finished building " . $builder->name );
  }

  $self->log('info', "finished building all requested tracks: " 
    . join(", ", map{ $_->name } @builders) );
}


###Future API
# Trying to build clean version... seems to have either a bug that results in locking
# or major performance issues
# for now, avoiding, and set $self->commitEvery in DBManager to 2000 to try to balance
# write performance and page allocation
# for now this only works on regular databases, not meta databases
# this works in a simple, mildly silly way for now
# if a chromosome is specified, it will copy that database
# then, it also tries to completely overwrite any gene and region type tracks
# because references to those could have been included in the main database
# # being copied
# sub BUILD_CLEAN {
#   my $self = shift;

#   my @builders;

#   my $refTrackBuilder = $self->getRefTrackBuilder();

#   #use the refTrackBuilder, which is the only required track
#   #to figure out which chromosomes are wanted
#   my @chrs = $refTrackBuilder->allWantedChrs;
#   undef $refTrackBuilder;

#   my @regionTracks = $self->allRegionTrackBuilders();

#   my @geneTracks = $self->allGeneTrackBuilders();

#   MCE::Loop::init {
#     max_workers => 26, chunk_size => 1
#   };

#   #first build clean copies of all wanted chrs
#   mce_loop {
#     my ($mce, $chunk_ref, $chunk_id) = @_;
#     MCE->say("Writing clean database copy of $_");
#     $self->dbWriteCleanCopy($_);
#   } @chrs;

#   if(@regionTracks) {
#     mce_loop {
#       my ($mce, $chunk_ref, $chunk_id) = @_;
#       MCE->say("Writing clean database copy of " . $_->name);
#       $self->dbWriteCleanCopy($_->name);
#     } @regionTracks;
#   }

#   if(@geneTracks) {
#     mce_loop {
#       my ($mce, $chunk_ref, $chunk_id) = @_;
#       MCE->say("Writing clean database copy of " . $_->name);
#       $self->dbWriteCleanCopy($_->name);
#     } @geneTracks;
#   }
# }

__PACKAGE__->meta->make_immutable;

1;
