use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Reference;

our $VERSION = '0.001';

# ABSTRACT: The getter for the reference track
# VERSION

use Moose 2;

use namespace::autoclean;

extends 'Seq::Tracks::Get';

__PACKAGE__->meta->make_immutable;

1;
