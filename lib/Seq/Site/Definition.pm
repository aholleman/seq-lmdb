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

has refBase => (
  is       => 'ro',
  isa      => 'reference_base_types',
  required => 1,
);

# type 'GeneTrackPositionalKeys',
#       where {
#           IsHashRef(
#               -keys   => HasLength,
#               -values => $positionalKeys
#           )->(@_);
#       };
# enum GeneTrackPositionalKeys => $positionalKeys;
#old annotation_type
#has annotationType => 

#<<< No perltidy
state $Eu_codon_2_aa = {
  "AAA" => "K", "AAC" => "N", "AAG" => "K", "AAT" => "N",
  "ACA" => "T", "ACC" => "T", "ACG" => "T", "ACT" => "T",
  "AGA" => "R", "AGC" => "S", "AGG" => "R", "AGT" => "S",
  "ATA" => "I", "ATC" => "I", "ATG" => "M", "ATT" => "I",
  "CAA" => "Q", "CAC" => "H", "CAG" => "Q", "CAT" => "H",
  "CCA" => "P", "CCC" => "P", "CCG" => "P", "CCT" => "P",
  "CGA" => "R", "CGC" => "R", "CGG" => "R", "CGT" => "R",
  "CTA" => "L", "CTC" => "L", "CTG" => "L", "CTT" => "L",
  "GAA" => "E", "GAC" => "D", "GAG" => "E", "GAT" => "D",
  "GCA" => "A", "GCC" => "A", "GCG" => "A", "GCT" => "A",
  "GGA" => "G", "GGC" => "G", "GGG" => "G", "GGT" => "G",
  "GTA" => "V", "GTC" => "V", "GTG" => "V", "GTT" => "V",
  "TAA" => "*", "TAC" => "Y", "TAG" => "*", "TAT" => "Y",
  "TCA" => "S", "TCC" => "S", "TCG" => "S", "TCT" => "S",
  "TGA" => "*", "TGC" => "C", "TGG" => "W", "TGT" => "C",
  "TTA" => "L", "TTC" => "F", "TTG" => "L", "TTT" => "F"
};

sub codon2aa {
  #my ( $self, $codon ) = @_;
  # if ( $Eu_codon_2_aa->{$codon} ) {
  #   return $Eu_codon_2_aa->{$codon};
  # } else {
  #   return;
  # }
  #$_[1] == $codon;

  #will return undefined if not found
  return $Eu_codon_2_aa->{ $_[1] };
}

state $codingSite = 'Coding';
has codingSiteType => (is=> 'ro', lazy => 1, default => sub{$codingSite} );
state $fivePrimeSite = '5UTR';
has fivePrimeSiteType => (is=> 'ro', lazy => 1, default => sub{$fivePrimeSite} );
state $threePrimeSite = '3UTR';
has threePrimeSiteType => (is=> 'ro', lazy => 1, default => sub{$threePrimeSite} );
state $spliceAcSite = 'Splice Acceptor';
has spliceAcSiteType => (is=> 'ro', lazy => 1, default => sub{$spliceAcSite} );
state $spliceDonSite = 'Splice Donor';
has spliceDonSiteType => (is=> 'ro', lazy => 1, default => sub{$spliceDonSite} );
state $ncRNAsite = 'non-coding RNA';
has ncRNAsiteType => (is=> 'ro', lazy => 1, default => sub{$ncRNAsite} );

=type {Str} VariantTypes, was SiteTypes, renamed to avoid confusion
=cut

enum VariantTypes => ['SNP', 'MULTIALLELIC', 'DEL', 'INS'];

=type {Str} GeneSiteType

=cut

#Coding type always first; order of interest
state $siteTypes = [$codingSite, $fivePrimeSite, $threePrimeSite,
$spliceAcSite, $spliceDonSite, $ncRNAsite];

#public
has siteTypes => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    allSiteTypes => 'elements',
    getSiteType => 'get',
  },
  lazy => 1,
  init_arg => undef,
  default => sub{$siteTypes},
);

#public
enum GeneSiteType => $siteTypes;

=type {Str} StrandType

=cut

state $strandTypes = [ '+' , '-'];

has strandTypes => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'ArrayRef',
  traits => ['Array'],
  default => sub {$strandTypes},
);

enum StrandType   => $strandTypes;

subtype 'GeneSites'=> as 'ArrayRef[GeneSiteType]';

__PACKAGE__->meta->make_immutable;

1;
