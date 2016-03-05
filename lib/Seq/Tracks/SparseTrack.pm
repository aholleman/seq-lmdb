use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::SparseTrack;

our $VERSION = '0.001';

# ABSTRACT: Configure a sparse traack
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Config::SparseTrack>

  Base class that decorates @class Seq::Build sql statements (@method
  sql_statement) and performs feature formatting.

Used in:

=begin :list
* @class Seq::Assembly
    Seq::Assembly @extends

      =begin :list
      * @class Seq::Annotate
          Seq::Annotate used in @class Seq only

  * @class Seq::Build
  =end :list
=end :list

@extends

=for :list
* @class Seq::Build::SparseTrack
* @class Seq::Build::GeneTrack
* @class Seq::Build::SnpTrack
* @class Seq::Build::TxTrack

=cut

use Moose 2;
use namespace::autoclean;

extends 'Seq::Base';

=type SparseTrackType

=for :list

1. gene

2. snp

=cut

# TODO: do we ever actually need a name parameter?

=property @required {ArrayRef<str>} features

  Defined in the configuration file in the heading feature.
  { sparse_tracks => features => [] }

@example

=for :list
* 'mRNA'
* 'spID'
* 'geneSymbol'

=cut


=method @public snp_fields_aref

  Returns array reference containing all (attribute_name => attribute_value}

Called in:

=for :list
* @class Seq::Build::SnpTrack
* @class Seq::Build::TxTrack

@requires:

=for :list
* {Str} $self->type (required by class constructor, guaranteed to be available)
* {ArrarRef<Str>} $self->features (required by class constructor, guaranteed to
  be available)

@returns {ArrayRef|void}

=cut
#TODO:
# sub snp_fields_aref {
#   my $self = shift;
#   if ( $self->type eq 'snp' ) {
#     my @out_array;
#     #resulting array is @snp_track_fields values followed @self->features values
#     push @out_array, @snp_track_fields, @{ $self->features };
#     return \@out_array;
#   }
#   else {
#     return;
#   }
# }

=method @public snp_fields_aref

  Returns array reference containing all {attribute_name => attribute_value}

Called in:

=for :list
* @class Seq::Build::GeneTrack
* @class Seq::Build::TxTrack

@requires:

=for :list
* @property {Str} $self->type (required by class constructor, guaranteed to be
  available)
* @property {ArrarRef<Str>} $self->features (required by class constructor,
  guaranteed to be available)

@returns {ArrayRef|void}

=cut
# TODO, but this belongs in GeneTrack
# sub gene_fields_aref {
#   my $self = shift;
#   if ( $self->type eq 'gene' ) {
#     my @out_array;
#     push @out_array, @gene_track_fields, @{ $self->features };
#     return \@out_array;
#   }
#   else {
#     return;
#   }
# }

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

# sub as_href {
#   my $self = shift;
#   my %hash;
#   my @attrs = qw/ name features genome_chrs genome_index_dir genome_raw_dir
#     local_files remote_dir remote_files type sql_statement/;
#   for my $attr (@attrs) {
#     if ( defined $self->$attr ) {
#       if ( $self->$attr eq 'genome_index_dir' or $self->$attr eq 'genome_raw_dir' ) {
#         $hash{$attr} = $self->$attr->stringify;
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
