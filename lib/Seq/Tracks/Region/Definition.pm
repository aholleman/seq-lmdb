#This is an "easy" but not elegant way of putting regions into the 
#fold
#We have one region key, which is a reference to whatever is in
#the region database
#we store this as if it's a feature
#and then all of the features the user defined
#are actually grabbed from the region database
package Seq::Tracks::Region::Definition;
use 5.16.0;
use strict;
use warnings;

use Moose::Role 2;
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

# has regionKey => (
#   is => 'ro',
#   isa => 'HashRef',
#   traits => ['Hash'],
#   handles => {
#     getRegionKeyDbName => 'get',
#   },
#   init_arg => undef,
#   lazy => 1,
#   default => sub { return { region => 0, } },
# );

has regionKey => (is => 'ro', lazy => 1, default => 'region' );

sub getRegionKeyDbName {
  return 0;
}

sub getRegionKeyName {
  return 'region';
}

sub regionPath {
  my ($self, $chr) = @_;

  return $self->name . "/$chr";
}

no Moose::Role;
