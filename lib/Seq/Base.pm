use 5.10.0;
use strict;
use warnings;

package Seq::Base;

our $VERSION = '0.002';

#All this does is initialize the messaging state, if passed, and extends Seq::Track
#which allows consuming classes to access the tracks.
use Moose 2;
use namespace::autoclean;

#whether we're building or annotating, we need Seq::Tracks
#this allows all arguments sent to any main Seq package to be picked up
#by Seq::Tracks, making config of that package easier
extends 'Seq::Tracks'; 

#Right now this is used to name the log file
#Not sure if this will continue to be used.
#removed genome_description, because assemblies already identify the species
#and becuase it isn't used anywhere in the Seq library
#genome_description (currently the species) has no prupose
has genome_name        => ( is => 'ro', isa => 'Str', required => 1, );

=property @public {Str} database_dir

  The path (relative or absolute) to the index folder, which contains all databases

  Defined in the required input yaml config file, as a key : value pair, and
  used by:
  @role Seq::Role::ConfigFromFile

  The existance of this directory is checked in Seq::Annotate::BUILDARGS

@example database_dir: hg38/index
=cut

has messanger => (
  is => 'ro',
  isa => 'HashRef',
  default => sub{ {} },
);

has publisherAddress => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => sub{ [] },
);

has logPath => (
  is => 'ro',
  lazy => 1,
  default => '',
);

#set up singleton stuff
sub BUILD {
  my $self = shift;
  
  if(%{$self->messanger} && @{$self->publisherAddress} ) {
    #p $self;
    $self->setPublisher($self->messanger, $self->publisherAddress);
  }

  if ($self->logPath) {
    $self->setLogPath($self->logPath);
  }

  #todo: finisih ;for now we have only one level
  if ( $self->debug ) {
    $self->setLogLevel('info');
  }
}

__PACKAGE__->meta->make_immutable;
1;
