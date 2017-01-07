use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Build::Definition;
use Mouse::Role 2;

#Defines a few keys common to the build and get functions of Tracks::Gene
######################## Public, Configurable ################################
has strandField => (is => 'ro', lazy => 1, default => 'strand');
has txStartField => (is => 'ro', lazy => 1, default => 'txStart');
has txEndField => (is => 'ro', lazy => 1, default => 'txEnd');
has chromField => (is => 'ro', lazy => 1, default => 'chrom');

######################## Public Exports ################################
has txErrorField => (is => 'ro', init_arg => undef, lazy => 1, default => 'txError');
has hasCdsField => (is => 'ro', init_arg => undef, lazy => 1, default => 'hasCds');
has tssField => (is => 'ro', init_arg => undef, lazy => 1, default => 'tss');

# has strandField => (is => 'ro', init_arg => undef, lazy => 1, default => 'strand');
# has txStartField => (is => 'ro', init_arg => undef, lazy => 1, default => 'strand');
# has strandField => (is => 'ro', init_arg => undef, lazy => 1, default => 'strand');
# has strandField => (is => 'ro', init_arg => undef, lazy => 1, default => 'strand');

#some default fields, some of which are required
#TODO: allow people to remap the names of required fields if their source
#file doesn't match (a bigger issue for sparse track than gene track)
state $ucscGeneAref = [
  'chrom',
  'strand',
  'txStart',
  'txEnd',
  'cdsStart',
  'cdsEnd',
  'exonCount',
  'exonStarts',
  'exonEnds',
  'name',
  'kgID',
  'mRNA',
  'spID',
  'spDisplayID',
  'geneSymbol',
  'refseq',
  'protAcc',
  'description',
  'rfamAcc',
];

has ucscGeneAref => (
  is => 'ro', 
  init_arg => undef, 
  lazy => 1, 
  default => sub { 
    return grep { $_ ne 'chrom' && $_ ne 'exonStarts' && $_ ne 'exonEnds' } @$ucscGeneAref; 
  },
  traits => ['Array'],
  handles => {
    allUCSCgeneFeatures => 'elements',
  }
);

no Mouse::Role;
1;