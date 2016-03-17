use 5.10.0;
use strict;
use warnings;

# Changes: We pre-calculate everything all possible changes in our database
# So this class doesn't have much to do

package Seq::Site::Annotation;

our $VERSION = '0.001';

# This should be a part of GeneTrack.
# All annotation should happen during building.

# ABSTRACT: Class for seralizing annotation sites
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Site::Annotation>

  This class performs the annotation of a variant site. It is created by data
  that comes from the gene site database.

Used in:

=begin :list
* @class Seq::Annotate
    Which is used in:

    =begin :list
    * bin/annotate_ref_site.pl
    * bin/read_genome_with_dbs.pl
    * @class Seq
    =end :list
=end :list

Extended in: None

=cut

use Moose 2;
use Moose::Util::TypeConstraints;

use namespace::autoclean;

extends 'Seq::Site::Gene';
with 'Seq::Role::Serialize';

=type non_missing_base_type<Str>

  Type constraint that allows only @values 'A','C','G','T'

  This excludes N, which is coded as a 0 {Char} @value
    @see Seq::Config::GenomeSizedTrack @variable %base_char_2_txt

=cut

enum non_missing_base_types => [qw( A C G T )];

my %comp_base_lu = ( A => 'T', C => 'G', G => 'C', T => 'A' );

has minor_allele => (
  is       => 'ro',
  isa      => 'non_missing_base_types',
  required => 1,
);

has new_codon_seq => (
  is      => 'ro',
  isa     => 'Maybe[Str]',
  lazy    => 1,
  builder => '_set_new_codon_seq',
);

has new_aa_residue => (
  is      => 'ro',
  isa     => 'Maybe[Str]',
  lazy    => 1,
  builder => '_set_new_aa_residue',
);

has annotation_type => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_set_annotation_type',
);

# we need to call the various methods to get them to populate
# TODO: consider changing serilization to rely on a sub routine of
#       prepopulated attributes, which might be a bit faster.
sub BUILD {
  my $self = shift;
  $self->annotation_type;
}

=method @private _set_new_codon_seq

  Sets the value of new_codon_seq; used in @class Seq::Site::Annotation @method @private _set_annotation_type
  to call codon Silent, Replacement, or Non-Coding if non-reference

@requires:

=for :list
* @property {Int|undef} $self->codon_position
  declared in @class Seq::Site::Gene
    Seq::Site::Gene also used in @class Seq::Gene
      Seq::Gene is used by @class Seq::Build::GeneTrack && @class Seq::Build::TxTrack

* @property {Str|undef} $self->ref_codon_seq
  declared in @classSeq::Site::Gene

* @property {non_missing_base_types} $self->minor_allele :

@returns {Str|void}

=cut

=type {Str} non_missing_base_types

  Custom Str type, enforced by Moose::Util::TypeConstraints. Defines non-ambiguous, non-heterozygote base codes

@values 'A','C','G' or 'T'

=cut

sub _set_new_codon_seq {
  my $self      = shift;
  my $new_codon = $self->ref_codon_seq;

  my $new_base =
    ( $self->strand eq '-' )
    ? $comp_base_lu{ $self->minor_allele }
    : $self->minor_allele;

  if ($new_codon) {
    substr( $new_codon, ( $self->codon_position ), 1, $new_base );
    return $new_codon;
  }
  else {
    return;
  }
}

=method @private _set_new_aa_residue

  Takes the $new_codon (held in property new_codon_seq), and returns the corresponding single-letter amino acid code

@requires:

=for :list
* @property {Str|undef} $self->new_codon_seq (optional)
* @method $self->codon_2_aa
    Defined in Seq::Site::Gene

@returns {Str|undef}
=cut

sub _set_new_aa_residue {
  my $self = shift;
  return $self->codon_2_aa( $self->new_codon_seq );
}

=method @private _set_annotation_type

    Takes the single-letter amino acid code if present

@requires:

=for :list
* @property {Str} $self->new_aa_residue
* @property {Str} $self->new_aa_residue
    Defined in @class Seq::Site::Gene

@returns {Str} @values 'Silent', 'Replacement', 'Non-Coding'

=cut

sub _set_annotation_type {
  my $self = shift;
  if ( $self->new_aa_residue ) {
    if ( $self->new_aa_residue eq $self->ref_aa_residue ) {
      return 'Silent';
    }
    else {
      return 'Replacement';
    }
  }
  else {
    return 'Non-Coding';
  }
}

__PACKAGE__->meta->make_immutable;

1;
