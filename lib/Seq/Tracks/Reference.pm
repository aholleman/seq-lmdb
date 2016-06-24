use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Reference;

our $VERSION = '0.001';

# ABSTRACT: The getter for the reference track
# VERSION

use Moose 2;
use DDP;

use namespace::autoclean;

use Seq::Tracks::Reference::MapBases;

state $baseMapper = Seq::Tracks::Reference::MapBases->new();

extends 'Seq::Tracks::Get';

sub get {
  # $_[0] == $self; $_[1] = dbDataAref
  return $baseMapper->baseMapInverse->{ $_[1]->{ $_[0]->dbName } };
}

__PACKAGE__->meta->make_immutable;

1;
