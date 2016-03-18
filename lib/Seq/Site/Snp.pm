use 5.10.0;
use strict;
use warnings;

# This package is no longer needed. Sparse tracks will just return 
# Whatever data is stored  in the Sparse Track
package Seq::Site::Snp;

our $VERSION = '0.001';

# ABSTRACT: A class for seralizing Snp sites
# VERSION

=head1 DESCRIPTION

  @class Seq::Site::Snp
  #TODO: Check description

  @example

Used in:
=for :list
* Seq::Annotate
* Seq::Build::SnpTrack

Extended by: None

=cut

use Moose 2;

use namespace::autoclean;

extends 'Seq::Site';
with 'Seq::Role::Serialize';

has snp_id => (
  is        => 'ro',
  isa       => 'Str',
  clearer   => 'clear_snp_id',
  predicate => 'has_snp_id',
);

has snp_feature => (
  is        => 'rw',
  isa       => 'HashRef',
  clearer   => 'clear_feature',
  predicate => 'has_feature',
  traits    => ['Hash'],
  handles   => {
    set_snp_feature  => 'set',
    get_snp_feature  => 'get',
    all_snp_features => 'elements',
    no_snp_feature   => 'is_empty',
  },
);

sub as_href {
  my $self = shift;
  my %hash;

  for my $attr ( $self->meta->get_all_attributes ) {
    my $name = $attr->name;
    if ( defined $self->$name ) {
      $hash{$name} = $self->$name;
    }
  }
  return \%hash;
}

__PACKAGE__->meta->make_immutable;

1;
