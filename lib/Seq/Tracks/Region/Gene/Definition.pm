#TODO: Merge this with Seq::Tracks::Region::Gene::TX::Definition as needed
#TODO: figure out a more elegant solution, esp. one using automatic 
#name convolution, instead of manual
package Seq::Tracks::Region::Gene::Definition;
use 5.16.0;
use strict;
use warnings;

use Moose::Role 2;
use Moose::Util::TypeConstraints;
use namespace::autoclean;
#use Declare::Constraints::Simple-All;

# Gene Tracks are a bit like cadd score tracks in that we need to match
# on allele
#We only need to konw these values; later everything is 
#The reason stuff other than chrom, txStart, txEnd are required is that we
#use cdsStart, cdsEnd, exonStarts exonEnds to determine whether we're in a 
#coding region, exon, etc
#Below is just a way for us to access all of the required keys
#we hardcode require keys here
#chrom   strand  txStart txEnd   cdsStart        
# cdsEnd  exonCount       exonStarts      exonEnds        name    
# kgID    mRNA    spID    spDisplayID     geneSymbol      
# refseq  protAcc description     rfamAcc

#we write variables as state because it's a bit faster
#than my http://www.perlmonks.org/?node_id=985472
#and these never need to be re-initialized; but this role
#could be called millions of times
#and we store these as variables because names may change
#or there may be small differences between different gene tracks
#and also because we need to give Moose key-value pairs 
#at creation time, so that it can check whether it has requisite data 
#for declared attributes
our $ucscGeneHref = {
  chrom => 'chrom',
  strand => 'strand',
  txStart => 'txStart',
  txEnd => 'txEnd',
  cdsStart => 'cdsStart',
  cdsEnd => 'cdsEnd',
  exonCount => 'exonCount',
  exonStarts => 'exonStart',
  exonEnds => 'exonEnds',
  name => 'name',
  kgID => 'kgID',
  mRNA => 'mRNA',
  spID => 'spID',
  spDisplayID => 'spDisplayID',
  geneSymbol => 'geneSymbol',
  refseq => 'refseq',
  protAcc => 'protAcc',
  description => 'description',
  rfamAcc => 'rfamAcc',
};

has allGeneTrackKeys => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'HashRef',
  default => sub{ $ucscGeneHref },
);

#we need chrKey to know where we are in the chromosome
#and the 
has chrKey => (is => 'ro', lazy => 1, default => sub{ $ucscGeneHref->{chrom} } );
has txStartKey => (is => 'ro', lazy => 1, default => sub{$ucscGeneHref->{txStart} } );
has txEndKey => (is => 'ro', lazy => 1, default => sub{ $ucscGeneHref->{txEnd} } );

#gene tracks are weird, they're not just like region tracks
#they also need to store some transcript information
#which is pre-calculated, for every site in the reference
#that's between txStart and txEnd
#it includes the strand, the site type, the codon number, and position of 
#that base within the codon; the latter two only if in an exon
#unfortunately, sources tell me that you can't augment attributes inside 
#of moose roles, so 
# has featureOverride => (
#   is => 'ro',
#   isa => 'HashRef',
#   lazy => 1,
#   init_arg => undef,
#   default => sub{ {
#     #TODO: for now this must be the same in the general region track
#     #fix it so that we don't need to declare the same spelling twice
#     region => 0,
#     tx  => 1,
#   } },
# );

#everything that we want to store in the region
# state $geneTrackRegionKeys;

#unfortunately, I believe that in the current setup, I need to make these 
#package variables

our $requiredFieldOverride;

for my $key (keys %$ucscGeneHref) {
  if($key eq 'exonStarts' || $key eq 'exonEnds') {
    next;
  }
  push @$requiredFieldOverride, $ucscGeneHref->{$key}; 
}

#hacks until we get automated name conversion working
our $featureFieldOverride = {
  region => 0,
  tx  => 1,
};

our $featureFieldOverrideInverse = {
  0 => 'region',
  1 => 'tx',
};



# has requiredFieldOverride => (
#   is => 'ro',
#   lazy => 1,
#   init_arg => undef,
#   isa => ['ArrayRef'],
#   builder => '_buildGeneTrackRegionKeys',
# );

# sub _buildGeneTrackRegionKeys {
#   if($geneTrackRegionKeys) {
#     return $geneTrackRegionKeys;
#   }

#   for my $key (keys %$ucscGeneHref) {
#     if($key eq 'exonStarts' || $key eq 'exonEnds') {
#       next;
#     }
#     push @$geneTrackRegionKeys, $ucscGeneHref->{$key}; 
#   }
#   return $geneTrackRegionKeys;
# }

no Moose::Role;
no Moose::Util::TypeConstraints;
1;