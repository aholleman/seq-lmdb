use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Reference;

our $VERSION = '0.001';

# ABSTRACT: Configure a genome-sized track
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Config::GenomeSizedTrack>

  A genome sized track is one that contains a {Char} for every position in the
  genome. There are three different types that are enumerated below.

  This class provides getters and setters for the management of these hashes.

  This class can be consumed directly:

    @example Seq::Config::GenomeSizedTrack->new($gst)

  Or as a Type Constraint:

    @example has => some_property ( isa => 'ArrayRef[Seq::Config::GenomeSizedTrack]' )

Used in:

=for :list
* @class Seq::Assembly
    Seq::Assembly is used in @class Seq::Annotate, which is used in @class Seq.pm

Extended in:

=for :list
* @class Seq::Build::GenomeSizedTrackStr
* @class Seq::GenomeBin
* @class Seq::Fetch::Sql

=cut

use Moose 2;

use namespace::autoclean;

extends 'Seq::Tracks::Get';

#This really is a simple class
#The default get method handles this just fine, as defined in Seq::Tracks::Get

=property @public @required {GenomeSizedTrackType<Str>} type

  The type of feature

  @values:

  =for :list
  * genome
    Only one feature of this type may exist
  * score
    The 1 binary, 1 offset file format. @example: PhyloP
  * cadd
    The N binary file format @example: CADD

=cut

=property {ArrayRef<Str>} genome_chrs

  An array reference holding the list of chromosomes in the genome assembly.
  The list of chromosomes is supplied by the configuration file.

Used in:

=for :list
* bin/make_fake_genome.pl
* bin/read_genome.pl
* bin/run_all_build.pl
* @class Seq::Annotate
* @class Seq::Assembly
* @class Seq::Build::GenomeSizedTrackStr
* @class Seq::Build
* @class Seq::Fetch

=cut


=method @private _build_score_lu

  Precompute all possible scores, for efficient lookup

@returns {HashRef}
  The score look up table. Keys are 0-255 (i.e., {Char} values), and the values
  are scores.

# TODO: Check if it's correct to say "Radian" values.
=cut


# sub get_idx_base {
#   my ( $self, $char ) = @_;
#   return $idx_base[$char];
# }

# sub get_idx_in_gan {
#   my ( $self, $char ) = @_;
#   return $idx_in_gan[$char];
# }

# sub get_idx_in_gene {
#   my ( $self, $char ) = @_;
#   return $idx_in_gene[$char];
# }

# sub get_idx_in_exon {
#   my ( $self, $char ) = @_;
#   return $idx_in_exon[$char];
# }

# =method @public get_idx_in_snp

#   Takes an integer code representing the features at a genomic position.
#   Returns a 1 if this position is a snp, or 0 if not

#   $self->get_idx_in_snp($site_code)

#   See the anonymous routine ~line 100 that fills $idx_in_snp.

# Used in @class Seq::Annotate

# @requires @private {Array<Bool>} $idx_in_snp

# @param {Int} $char

# @returns {Bool} @values 0, 1

# =cut

# sub get_idx_in_snp {
#   my ( $self, $char ) = @_;
#   return $idx_in_snp[$char];
# }

# =method @public get_idx_in_snp

#   @see get_idx_in_snp

# =cut

# sub in_gan_val {
#   my $self = @_;
#   return $in_gan[1];
# }

# =method @public get_idx_in_snp

#   @see get_idx_in_snp

# =cut

# sub in_exon_val {
#   my $self = @_;
#   return $in_exon[1];
# }

# =method @public get_idx_in_snp

#   @see get_idx_in_snp

# =cut

# sub in_gene_val {
#   my $self = @_;
#   return $in_gene[1];
# }

# =method @public get_idx_in_snp

#   @see get_idx_in_snp

# =cut

# sub in_snp_val {
#   my $self = @_;
#   return $in_snp[1];
# }

=constructor

  Overrides BUILDARGS construction function to set default values for (if not set):

  =for :list
  * @property {Int} score_R
  * @property {Int} score_min
  * @property {Int} score_max

@requires

=for :list
* @property {Str} type
* @property {Str} name

@returns {$class->SUPER::BUILDARGS}

=cut

=method @public as_href

  Returns hash reference containing data needed to create BUILD and annotate
  stuff... (i.e., no internals and not all public attributes)

Used in:

=for :list
* @class Seq::Build::GeneTrack
* @class Seq::Build::SnpTrack
* @class Seq::Build

Uses Moose built-in meta method.

@returns {HashRef}

=cut

# TODO: edit as_href to export data needed for BUILD and annotation stuff

# sub as_href {
#   my $self = shift;
#   my %hash;
#   my @attrs = qw/ name genome_chrs genome_index_dir genome_raw_dir
#     local_files remote_files remote_dir type/;
#   for my $attr (@attrs) {
#     if ( defined $self->$attr ) {
#       if ( $self->$attr eq 'genome_index_dir' or $self->$attr eq 'genome_raw_dir' ) {
#         $hash{$attr} = $self->$attr->absolute->stringify;
#       }
#       elsif ( $self->$attr ) {
#         $hash{$attr} = $self->$attr;
#       }
#     }
#   }
#   return \%hash;
# }

__PACKAGE__->meta->make_immutable;

1;
