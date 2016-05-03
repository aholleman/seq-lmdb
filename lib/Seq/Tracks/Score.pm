use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Score;

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

# enum BinType => [ 'C', 'n' ];
extends 'Seq::Tracks::Get';

override 'BUILD' => sub {
  my $self = shift;

  $self->addFeaturesToTrackHeaders($self->name);

  super();
};
#Every track needs to have a feature name for each of the values it returns
#(values can be scalar, hashRef, arrayRef)
#for a score track, that is simply the name of the track itself
#ex: cadd, phyloP, phastCons, etc
# has '+features' => (
#   default => sub {
#     my $self = shift;
#     return $self->name;
#   }
# );
=property @public {StrRef} bin_seq

  Stores one binary genome sized track as a scalar reference (reference to a
  3.2B base string). This can be the reference genome, one of the 3 CADD score
  binary indices (one for each base change possibility), or a genome-size
  'score' type like PhastCons or PhyloP

Used in:

=for :list
* @class Seq::Annotate
    Seq::Annotate sets the bin_seq values on line 286
* @class Seq:::GenomeBin

@example from @class Seq::Annotate _load_cadd_score:

  my $index_dir = $self->genome_index_dir;
  my $idx_name = join( ".", $gst->type, $i );
  my $idx_file = File::Spec->catfile( $index_dir, $idx_name );
  my $idx_fh = $self->get_read_fh($idx_file);
  $seq = '';
  read $idx_fh, $seq, $genome_length;

=cut


# dropped defining the binary type and just have different methods
#   that work for differently encoded strings
#has bin => (
#  is => 'ro',
#  isa => 'BinType',
#  required => 1,
#  default => 'C',
#);

=method @public get_base

  Returns the genome index code for the absolute position of the genome supplied; 
  the absolute position is assumed to be zero indexed

@param $pos
  The zero-indexed absolute genomic position
@requires
=for :list
* @property genome_length
* @property bin_seq
    The full binary genome sized track

@ returns {Str} in the form of a Char representing the value at that position.

=cut

#TODO:
# sub get_base {
#   my ( $self, $pos ) = @_;
#   state $genome_length = $self->_get_genome_length;

#   if ( $pos >= 0 and $pos < $genome_length ) {
#     return unpack( 'C', substr( ${ $self->bin_seq }, $pos, 1 ) );
#   }
#   else {
#     confess "get_base() expects a position between 0 and $genome_length, got $pos.";
#   }
# }

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

#TODO: but this should be in GeneTrack
# sub get_nearest_gene {
#   my ( $self, $pos ) = @_;

#   state $genome_length = $self->_get_genome_length;

#   if ( $pos >= 0 and $pos < $genome_length ) {
#     return unpack( 'n', substr( ${ $self->bin_seq }, $pos * 2, 2 ) );
#   }
#   else {
#     confess "get_base() expects a position between 0 and $genome_length, got $pos.";
#   }
# }

=method @public get_score

=cut

# TODO:
# sub get_score {
#   my ( $self, $pos ) = @_;

#   confess "get_score() requires absolute genomic position (0-index)"
#     unless defined $pos;
#   confess "get_score() called on non-score track"
#     unless $self->type eq 'score'
#     or $self->type eq 'cadd';

#   my $char            = $self->get_base($pos);
#   my $score           = $self->get_score_lu($char);
#   my $formatted_score = ( $score eq 'NA' ) ? $score : sprintf( "%0.3f", $score );
#   return $formatted_score;
# }

__PACKAGE__->meta->make_immutable;

1;
