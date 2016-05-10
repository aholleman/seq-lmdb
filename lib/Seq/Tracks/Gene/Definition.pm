use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Definition;
use Moose::Role 2;
#Defines a few keys common to the build and get functions of Tracks::Gene

#these are two features that are used in the main database
has siteFeatureName => (is => 'ro', init_arg => undef, lazy => 1, default => 'site');
has nearestGeneFeatureName => (is => 'ro', init_arg => undef, lazy => 1, default => 'nearest');

#these is features used in the region database
has geneTrackRegionDatabaseTXerrorName => (is => 'ro', init_arg => undef, lazy => 1, default => 'txError');

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
    defaultUCSCgeneFeatures => 'elements',
  }
);

no Moose::Role;
1;