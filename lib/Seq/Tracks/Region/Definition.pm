# Handles items common to Region tracks
package Seq::Tracks::Region::Definition;
use 5.16.0;
use strict;
use warnings;

use Moose::Role 2;
use namespace::autoclean;

requires 'name';

has regionNearestSubTrackName => (is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;

  return $self->name . '.nearest';
});

sub regionTrackPath {
  my ($self, $chr) = @_;

  return $self->name . "/$chr";
}

no Moose::Role;
1;
