# Handles items common to Region tracks
package Seq::Tracks::Region::RegionTrackPath;
use 5.16.0;
use strict;
use warnings;

use Moose::Role 2;

sub regionTrackPath {
  my ($self, $chr) = @_;

  return $self->name . "/$chr";
}

no Moose::Role;
1;
