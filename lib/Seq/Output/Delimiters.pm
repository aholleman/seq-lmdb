use 5.10.0;
use strict;
use warnings;

package Seq::Output::Delimiters;
use Mouse 2;

has primaryDelimiter => (is => 'ro', default => ';');

has secondaryDelimiter => (is => 'ro', default => '|');

has fieldSeparator => (is => 'ro', default => "\t");

__PACKAGE__->meta->make_immutable();
return 1;