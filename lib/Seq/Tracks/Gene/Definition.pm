use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Definition;
use Moose::Role 2;
#Defines a few keys common to the build and get functions of Tracks::Gene

has siteFeatureName => (is => 'ro', init_arg => undef, lazy => 1, default => 'site');
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
has ucscGeneAref => (is => 'ro', lazy => 1, default => sub{ $ucscGeneAref } );

#this is a hardcoded track for which we don't really expect the user
#to know to specify features they want in the region database
#so let's give them a sensible default
has '+features' => (
  default => sub{ grep { $_ ne 'exonStarts' && $_ ne 'exonEnds'} @$ucscGeneAref; },
);

no Moose::Role;
1;