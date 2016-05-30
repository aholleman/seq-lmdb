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

  #this could be cleaner, we're assuming buildTrack also knows about the wanted chr
  #would be nice to be able to pass the wanted chr to the buildTrack method
  for my $chr (@chrs) {
    if( !$refTrackBuilder->isCompleted($chr) ) {
      $self->log('info', "Detected that reference track isn\'t built for $chr. Building");
      
      $refTrackBuilder->buildTrack();
      
      $self->log('info', "Finished building the requisite reference track, 
        called " . $refTrackBuilder->name);
    }
  }
    
  #TODO: check whether ref built, and if not, build it, since many packages
  #may need it
  for my $builder (@builders) {
    #we already built the refTrackBuilder
    #could also just check for reference equality,
    #but this is more robust if we end up not using singletons at some point
    #all track names must be unique as a global requirement, so this is safe
    #and of course if the user requests we overwrite, lets respect that
    if($builder->name eq $refTrackBuilder->name && ! $self->overwrite) {
      next;
    }

    $self->log('info', "started building " . $builder->name );
   
    $builder->buildTrack();
    
    $self->log('info', "finished building " . $builder->name );
  }

  $self->log('info', "finished building all requested tracks: " 
    . join(", ", map{ $_->name } @builders) );
}

__PACKAGE__->meta->make_immutable;

1;
