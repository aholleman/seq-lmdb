package Seq::Site::Gene::Definition;

#This is now used to pre-calculate all potential changes
#For rapid lookup.

our $VERSION = '0.001';

# ABSTRACT: A class for storing defintions and codon table
# VERSION

use Moose::Role;
use 5.10.0;
use Moose::Util::TypeConstraints;

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

sub codon_2_aa {
  my ( $self, $codon ) = @_;
  if ($codon) {
    return $Eu_codon_2_aa->{$codon};
  }
  else {
    return;
  }
}

#private
#for API: Coding type always first; order of interest
state $siteTypes = ['Coding', '5UTR', '3UTR',
'Splice Acceptor', 'Splice Donor', 'non-coding RNA'];

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
=type {Str} SiteTypes
=cut

enum SiteTypes => ['SNP', 'MULTIALLELIC', 'DEL', 'INS'];






=type {Str} GeneSiteType

=cut

#public
enum GeneSiteType => $siteTypes;






=type {Str} StrandType

=cut

enum StrandType   => [ '+', '-' ];

subtype 'GeneSites'=> as 'ArrayRef[GeneSiteType]';

#>>>

no Moose::Role;
1;
