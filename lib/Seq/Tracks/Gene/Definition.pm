use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Definition;
use Mouse::Role 2;
#Defines a few keys common to the build and get functions of Tracks::Gene

#these is features used in the region database
#can be overwritten if needed in the config file, as described in Tracks::Build
has txErrorField => (is => 'ro', init_arg => undef, lazy => 1, default => 'txError');
has hasCdsField => (is => 'ro', init_arg => undef, lazy => 1, default => 'hasCds');
has strandField => (is => 'ro', init_arg => undef, lazy => 1, default => 'strand');

has txStartField => (is => 'ro', init_arg => undef, lazy => 1, default => 'txStart');
has txEndField => (is => 'ro', init_arg => undef, lazy => 1, default => 'txEnd');

has chromField => (is => 'ro', lazy => 1, default => 'chrom' );

has txStartField => (is => 'ro', lazy => 1, default => 'txStart' );
has txEndField => (is => 'ro', lazy => 1, default => 'txEnd' );

# These fields we want to be present in every gene track
has coreGeneFeatures => (
  is => 'ro', 
  init_arg => undef, 
  lazy => 1, 
  default => sub { 
    my $self = shift;
    return [$self->strandField, $self->txStartField, $self->txEndField];
  },
  traits => ['Array'],
  handles => {
    allUCSCgeneFeatures => 'elements',
  }
);

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