use 5.10.0;
use strict;
use warnings;

package Seq::Site::Definition;

our $VERSION = '0.001';

# ABSTRACT: Base class for seralizing all sites.
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Site>
  #TODO: Check description

  @example

Used in: None

Extended in:
=for :list
* Seq::Site::Gene
* Seq::Site::Snp

=cut

use Moose::Role 2;
use Moose::Util::TypeConstraints;

use namespace::autoclean;

enum reference_base_types => [qw( A C G T N )];



=type {Str} VariantTypes, was SiteTypes, renamed to avoid confusion
=cut

state $variantTypes = ['SNP', 'MULTIALLELIC', 'DEL', 'INS'];
#a type constraint for Moose attrs
enum VariantTypes => ['SNP', 'MULTIALLELIC', 'DEL', 'INS'];

has validVariantTypes => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    isValidVariantType => 'exists',
  },
  lazy => 1,
  init_arg => undef,
  default => sub {
    return map { $_ => 1} keys @$variantTypes;
  }
);

=type {Str} StrandType

=cut

state $strandTypes = [ '+' , '-'];

has strandTypes => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    allStrandTypes => 'elements',
  },
  default => sub {$strandTypes},
);

enum StrandType   => $strandTypes;

#subtype 'GeneSites'=> as 'ArrayRef[GeneSiteType]';

no Moose::Role;
1;
