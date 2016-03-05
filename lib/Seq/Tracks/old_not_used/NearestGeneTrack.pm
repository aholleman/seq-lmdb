use 5.10.0;
use strict;
use warnings;

#old GenomeBin
package Seq::NearestGene;

our $VERSION = '0.001';

# ABSTRACT: Decodes genome sized char tracks - genomes, scores, etc.
# VERSION

=head1 DESCRIPTION

  @class B<Seq::GenomeBin>

  The class that stores the complete reference genome

  Seq::Config::GenomeSizedTrack->new($gst)

Used in:

=for :list
* bin/read_genome.pl
* @class Seq::Annotate
* @class Seq::Config::GenomeSizedTrack

Extended in:

=for :list
* @class Seq::Build::GenomeSizedTrackStr
* @class Seq::GenomeBin
* @class Seq::Fetch::Sql

=cut

use Moose 2;
use Moose::Util::TypeConstraints;

use Carp qw/ confess croak /;
use File::Path;
use File::Spec;
use namespace::autoclean;
use Scalar::Util qw/ reftype /;

with 'Seq::Role::IO', 'Seq::Role::Genome', 'Seq::Role::DBManager';

=method @public get_nearest_gene

  Returns the gene number for the nearest gene to the absolute position;
  the absolute position is assumed to be zero indexed
  
@param $pos
  The zero-indexed absolute genomic position
@requires
=for :list
* @property genome_length
* @property bin_seq
    The full binary genome sized track (16-bit in network order)

@ returns the gene number

=cut
has key_name => {
  is => 'ro',
  default => 'ngene',
};

sub get {
  my ( $self, $chr, $href ) = @_;

  my $nearestPos = $href->{$self->key_name};

  return $self->db_get($chr, $nearestPos);
}

__PACKAGE__->meta->make_immutable;

1;
