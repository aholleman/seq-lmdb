#TODO: Merge this with Seq::Tracks::Region::Gene::TX::Definition as needed
#TODO: figure out a more elegant solution, esp. one using automatic 
#name convolution, instead of manual
package Seq::Tracks::Gene::Definition;
use 5.16.0;
use strict;
use warnings;

use Moose::Role 2;
use Moose::Util::TypeConstraints;
use namespace::autoclean;
with 'Seq::Tracks::Region::Definition';
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

#This declares an implicit name for each in the form

 # key = valueInArrayAtThisPosition
# and as usual each key is also stored as a number in the database
# for now, since we're hardcoding, that database name will just be the index
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

has chrFieldName => (is => 'ro', lazy => 1, default => sub{ $ucscGeneAref->[0] } );
# has txStartFieldName => (is => 'ro', lazy => 1, default => sub{$ucscGeneAref->[2] } );
# has txEndFieldName => (is => 'ro', lazy => 1, default => sub{ $ucscGeneAref->[3] } );

#make some indices, to help us get these values back
#moved away from native moose methods, because they turned out to be really verbose
#this is where we use the index values to get the "DbName"
state $ucscGeneIdx;
state $ucscGeneInvIdx;
state $geneTrackRegionFeaturesAref;
for (my $i=0; $i < @$ucscGeneAref; $i++) {

  #the database name is stored, on the human readable name key
  $ucscGeneIdx->{ $ucscGeneAref->[$i] } = $i;
  #the human readable name is stored on the database name key
  $ucscGeneInvIdx->{ $i } =  $ucscGeneAref->[$i];

  if( $ucscGeneAref->[$i] ne 'exonStarts' && $ucscGeneAref->[$i] ne 'exonEnds') {
    push @$geneTrackRegionFeaturesAref, $ucscGeneAref->[$i];
  }
}

#just the stuff meant for the region, above we exclude exonStarts and exonEnds
has geneTrackFieldNamesForRegion => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'ArrayRef',
  default => sub{ $geneTrackRegionFeaturesAref },
  traits => ['Array'],
  handles => {
    allGeneTrackRegionFeatureNames => 'elements',
    
  },
);

sub getGeneTrackRegionFeatDbName {
  my ($self, $name) = @_;

  return $ucscGeneIdx->{$name};
}

sub getGeneTrackRegionFeatName {
  my ($self, $dbName) = @_;

  return $ucscGeneIdx->{$dbName};
}

#all of the keys
has geneTrackFeatureNamesForRegionDatabase => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    'allGeneTrackFeatureNames' => 'elements',
  },
  default => sub{ $ucscGeneAref }, #must be non-reference scalar
);

#whatever should go into the main database
#region key is 0 in the included "Seq::Tracks::Region::Definition"
#but to make life easy, and since we don't need to comply with the
#Region interface anyway (because of codon & ngene key) I redeclare here

#codon is meant to hold some data that Gene::Site knows how to handle
#and ngene is meant to hold some data the Gene::NearestGene knows how to handle

state $ngeneDbName = 1;
state $codonDbName = 2;
state $ngeneName = 'ngene';
state $codonName = 'site';
has geneTrackFeaturesForMainDatabase => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'HashRef',
  default => sub{ 
    my $self = shift;

    if($self->getRegionFeatureDbName != 0) {
      $self->tee_logger('error', 'Region Feature Db Name should be 0');
      die 'Region Feature Db Name should be 0';
    }

    return { 
      $self->regionReferenceFeatureName => $self->regionReferenceFeatureDbName,
      $ngeneName  => $ngeneDbName,
      $codonName  => $codonDbName,
    } 
  },
  traits => ['Hash'],
  handles => {
    #We could be even more verbose with this name, but no need
    #because Gene Tracks only have a few features. One is the region reference
    getGeneTrackFeatureDbName => 'get',
  }
);

has _geneTrackFeaturesForMainDbNameInverse => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'HashRef',
  default => sub{ 
    my $self = shift; 

    if($self->getRegionFeatureDbName != 0) {
      $self->tee_logger('error', 'Region Feature Db Name should be 0');
      die 'Region Feature Db Name should be 0';
    }

    return { 
      $self->regionReferenceFeatureDbName => $self->regionReferenceFeatureName,
      $ngeneDbName => $ngeneName.
      $codonDbName => $codonName,
    } 
  },
  traits => ['Hash'],
  handles => {
    getGeneTrackFeatureName => 'get',
  }
);

no Moose::Role;
no Moose::Util::TypeConstraints;
1;