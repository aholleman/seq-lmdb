use 5.10.0;
use strict;
use warnings;

#Breaking this thing down to fit in the new contxt
#based on Seq::Gene in (kyoto-based) seq branch
#except _get_gene_data moved to Seq::Tracks::GeneTrack::Build
package Seq::Tracks::Region::Gene::TX::Definition;

our $VERSION = '0.001';

# ABSTRACT: Role that defines the structure of a transcript, essentially the
# basic fields from a UCSC gene track (RefSeq or Known Gene) that we need
# to make transcript information
# Should also methods that must always be implemented by every consumer

# VERSION

use Moose::Role 2;
use Seq::Tracks::ReferenceTrack;
with 'Seq::Site::Definition';

use namespace::autoclean;


#this doesn't really seem to add anything
#because we moved codon_2_aa out to Seq::Site::Gene::Definition
#ref_codon_seq , and ref_aa_residue just wraps that
#use Seq::Site::Gene;
has referenceTrack => (
  is       => 'ro',
  init_arg => undef,
  defulat  => sub{ Seq::Tracks::ReferenceTrack->new() },
  handles  => {
    getRefBase => 'get',
  }
);

has chrom        => ( is => 'rw', isa => 'Str', required => 1, );
has strand       => ( is => 'rw', isa => 'StrandType', required => 1, );
has txStart      => ( is => 'rw', isa => 'Int', required => 1, );
has txEnd        => ( is => 'rw', isa => 'Int', required => 1, );
has cdsStart     => ( is => 'rw', isa => 'Int', required => 1, );
has cdsEnd       => ( is => 'rw', isa => 'Int', required => 1, );

has exonStarts => (
  is       => 'rw',
  isa      => 'ArrayRef[Int]',
  required => 1,
  coerce   => 1,
  traits   => ['Array'],
  handles  => {
    all_exon_starts => 'elements',
    get_exon_starts => 'get',
    set_exon_starts => 'set',
  },
);

has exonEnds => (
  is       => 'rw',
  isa      => 'ArrayRef[Int]',
  required => 1,
  coerce   => 1,
  traits   => ['Array'],
  handles  => {
    all_exon_ends => 'elements',
    get_exon_ends => 'get',
    set_exon_ends => 'set',
  },
);

#transcript_id
has name => ( is => 'rw', isa => 'Str', required => 1, );

#private, meant to speed up introspection
#TODO: finish, and implement in Tracks::Region::Gene::Definition
has _allKeys => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  builder => '_build'
)
#use introspection
state $keysHref;
no Moose::Role;
1;
