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

#This declares an implicit name for each 
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

has chrKey => (is => 'ro', lazy => 1, default => sub{ $ucscGeneAref->[0] } );
has txStartKey => (is => 'ro', lazy => 1, default => sub{$ucscGeneAref->[2] } );
has txEndKey => (is => 'ro', lazy => 1, default => sub{ $ucscGeneAref->[3] } );

#make some indices, to help us get these values back
#moved away from native moose methods, because they turned out to be really verbose
state $ucscGeneIdx;
state $ucscGeneInvIdx;
state $geneTrackRegionFeaturesAref;
for (my $i=0; $i < @$ucscGeneAref; $i++) {
  $ucscGeneIdx->{ $ucscGeneAref->[$i] } = $i;
  $ucscGeneInvIdx->{ $i } =  $ucscGeneAref->[$i];

  if( $ucscGeneAref->[$i] ne 'exonStarts' && $ucscGeneAref->[$i] ne 'exonEnds') {
    push @$geneTrackRegionFeaturesAref, $ucscGeneAref->[$i];
  }
}

#just the stuff meant for the region, above we exclude exonStarts and exonEnds
has geneTrackKeysForRegion => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'ArrayRef',
  default => sub{ $geneTrackRegionFeaturesAref },
  traits => ['Array'],
  handles => {
    allGeneTrackRegionFeatures => 'elements',
    
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
has geneTrackKeys => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    'allGeneTrackKeys' => 'elements',
  },
  default => sub{ $ucscGeneAref }, #must be non-reference scalar
);

#whatever should go into the main database
#region key is 0 in the included "Seq::Tracks::Region::Definition"
#but to make life easy, and since we don't need to comply with the
#Region interface anyway (because of codon & ngene key) I redeclare here

#codon is meant to hold some data that Gene::Site knows how to handle
#and ngene is meant to hold some data the Gene::NearestGene knows how to handle
has geneTrackKeysForMain => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'HashRef',
  default => sub{ 
    my $self = shift; 
    return { 
      region => 0,
      ngene  => 1,
      site  => 2,
    } 
  },
  traits => ['Hash'],
  handles => {
    getGeneTrackFeatMainDbName => 'get',
  }
);

has _geneTrackKeysForMainDbNameInverse => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  isa => 'HashRef',
  default => sub{ 
    my $self = shift; 
    return { 
      0 => 'region',
      1 => 'ngene'.
      2 => 'site',
    } 
  },
  traits => ['Hash'],
  handles => {
    getGeneTrackMainFeatName => 'get',
  }
);


#Moved away from the below geneTrackKeysForRegion etc because
#awfully verbose
#whatever should go into the region
# has geneTrackKeysForRegion => (
#   is => 'ro',
#   lazy => 1,
#   init_arg => undef,
#   isa => 'HashRef',
#   builder => '_buildGeneTrackKeysForRegion',
#   traits => ['Hash'],
#   handles => {
#     getGeneTrackRegionFeatDbName => 'get',
#     allGeneTrackRegionFeatures => 'keys',
#   },
# );

# sub _buildGeneTrackKeysForRegion {
#   #$self == $_[0];
#   my $href;
#   for my $key (keys @$ucscGeneIdx) {
#     # for my $key (keys %$ucscGeneHref) {
#     if($key eq 'exonStarts' || $key eq 'exonEnds') {
#       next;
#     }
#    $href->{$key} = $ucscGeneIdx->{$key}; 
#   }
#   return $href;
# }

# has _geneTrackKeysForRegionInverted => (
#   is => 'ro',
#   lazy => 1,
#   init_arg => undef,
#   isa => 'HashRef',
#   builder => '_buildGeneTrackKeysForRegionInverted',
#   traits => ['Hash'],
#   handles => {
#     getGeneTrackRegionFeatName=> 'get',
#   },
# );

# sub _buildGeneTrackKeysForRegionInverted {
#   #$self == $_[0];
#   my $href;
#   for my $key (keys @$ucscGeneIdx) {
#     # for my $key (keys %$ucscGeneHref) {
#     if($key eq 'exonStarts' || $key eq 'exonEnds') {
#       next;
#     }
#    $href->{ $ucscGeneIdx->{$key} } = $key; 
#   }
#   return $href;
# }

# has geneTrackKeysForRegionInverted => (
#   is => 'ro',
#   lazy => 1,
#   init_arg => undef,
#   isa => 'HashRef',
#   builder => '_buildGeneTrackKeysForRegion',
# );


# has chrKey => (is => 'ro', lazy => 1, default => sub{ $ucscGeneAref->[0] } );
# has txStartKey => (is => 'ro', lazy => 1, default => sub{$ucscGeneHref->[2] } );
# has txEndKey => (is => 'ro', lazy => 1, default => sub{ $ucscGeneHref->[3] } );

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

# our $reqFields;

# for my $key (keys %$ucscGeneHref) {
#   if($key eq 'exonStarts' || $key eq 'exonEnds') {
#     next;
#   }
#   push @$reqFields, $ucscGeneHref->{$key}; 
# }

# #hacks until we get automated name conversion working
# our $featureFields = {
#   region => 0,
#   tx  => 1,
# };



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