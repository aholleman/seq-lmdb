#TODO: Figure out if still needed
use 5.10.0;
use strict;
use warnings;

package Seq::Site::Gene;

our $VERSION = '0.001';

# ABSTRACT: Class for seralizing gene sites
# VERSION

=head1 DESCRIPTION

  @class Seq::Site::Gene
  #TODO: Check description

  @example
  $gene_site{abs_pos}       = $self->get_transcript_abs_position($i);
  $gene_site{alt_names}     = $self->alt_names;
  $gene_site{ref_base}      = $self->get_base_transcript_seq( $i, 1 );
  $gene_site{error_code}    = $self->transcript_error;
  $gene_site{transcript_id} = $self->transcript_id;
  $gene_site{strand}        = $self->strand;

  # is site coding
  if ( $site_annotation =~ m/[ACGT]/ ) {
    $gene_site{site_type}      = 'Coding';
    $gene_site{codon_number}   = 1 + int( ( $coding_base_count / 3 ) );
    $gene_site{codon_position} = $coding_base_count % 3;
    my $codon_start = $i - $gene_site{codon_position};
    my $codon_end   = $codon_start + 2;

    #say "codon_start: $codon_start, codon_end: $codon_end, i = $i, coding_bp = $coding_base_count";
    for ( my $j = $codon_start; $j <= $codon_end; $j++ ) {
      $gene_site{ref_codon_seq} .= $self->get_base_transcript_seq( $j, 1 );
    }
    $coding_base_count++;
  }
  elsif ( $site_annotation eq '5' ) {
    $gene_site{site_type} = '5UTR';
  }
  elsif ( $site_annotation eq '3' ) {
    $gene_site{site_type} = '3UTR';
  }
  elsif ( $site_annotation eq '0' ) {
    $gene_site{site_type} = 'non-coding RNA';
  my $site = Seq::Site::Gene->new( \%gene_site );

Used in:
=for :list
* Seq::Gene
*

Extended by:
=for :list
* Seq::Site::Annotation

=cut

use Moose 2;
use Moose::Util::TypeConstraints;

use namespace::autoclean;

extends 'Seq::Site';
with 'Seq::Site::Definition';

has name => (
  is        => 'ro',
  isa       => 'Str',
  required  => 1,
  predicate => 'has_name',
);

has siteType => (
  is        => 'ro',
  isa       => 'GeneSiteType',
  required  => 1,
  predicate => 'has_site_type',
);

has strand => (
  is        => 'ro',
  isa       => 'StrandType',
  required  => 1,
  predicate => 'has_strand',
);

# amino acid residue # from start of transcript
has codonNumber => (
  is        => 'ro',
  isa       => 'Maybe[Int]',
  default   => sub { undef },
  predicate => 'has_codon_site_pos',
);

has codonPosition => (
  is        => 'ro',
  isa       => 'Maybe[Int]',
  default   => sub { undef },
  predicate => 'has_aa_residue_pos',
);

#not completely certain what this does
# has alt_names => (
#   is      => 'ro',
#   isa     => 'HashRef',
#   traits  => ['Hash'],
#   handles => { no_alt_names => 'is_empty', },
# );

has errorCode => (
  is        => 'ro',
  isa       => 'ArrayRef',
  predicate => 'has_error_code',
  traits    => ['Array'],
  handles   => { no_error_code => 'is_empty', },
);

# the following are attributs with respect to the reference genome

# codon at site
has refCodonSeq => (
  is        => 'ro',
  isa       => 'Maybe[Str]',
  default   => sub { undef },
  predicate => 'has_codon',
);

has refAAresidue => (
  is      => 'ro',
  isa     => 'Maybe[Str]',
  lazy    => 1,
  builder => '_set_ref_aa_residue',
);

sub _set_ref_aa_residue {
  my $self = shift;
  if ( $self->ref_codon_seq ) {
    return $self->codon_2_aa( $self->ref_codon_seq );
  }
  else {
    return;
  }
}

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
