use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::ScoreTrack::Build;

our $VERSION = '0.001';

# ABSTRACT: Base class for sparse track building
# VERSION

=head1 DESCRIPTION

  @class Seq::Build::SparseTrack
  #TODO: Check description
  A Seq::Build package specific class, used to define the disk location of the input

  @example

Used in:
=for :list
*

Extended by:
=for :list
* Seq/Build/GeneTrack.pm
* Seq/Build/TxTrack.pm

=cut

use Moose 2;

use Carp qw/ croak /;
use namespace::autoclean;

extends 'Seq::Tracks::Build';

#do we really need 'name'
state $requiredFields  = ['chrom','chromStart','chromEnd', 'name'];
has requiredFields => (
  is      => 'ro',
  isa     => 'ArrayRef',
  init_arg => undef,
  lazy => 1,
  builder => '_buildRequiredFields',
);

sub _buildRequiredFields {
  my $self = shift;

  my @out;
  push @out, @{$requiredFields}, @{$self->features};
  return \@out;
}

has force => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
);

has debug => (
  is      => 'ro',
  isa     => 'Int',
  default => 0,
);

sub _check_header_keys {
  my ( $self, $header_href, $req_header_aref ) = @_;
  my %missing_attr;
  for my $req_attr (@$req_header_aref) {
    $missing_attr{$req_attr}++ unless exists $header_href->{$req_attr};
  }
  if (%missing_attr) {
    my $err_msg =
      sprintf(
      "ERROR: Missing expected header information for track_name: %s of type %s: '%s'",
      $self->name, $self->type, join ", ", ( sort keys %missing_attr ) );
    $self->_logger->error($err_msg);
    croak $err_msg;
  }
  else {
    return;
  }
}

__PACKAGE__->meta->make_immutable;

1;
