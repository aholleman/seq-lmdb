package Seq::Genotypes;

our $VERSION = '0.001';

# ABSTRACT: A class for converting genotyping codes
# VERSION

use strict;
use warnings;
use 5.10.0;

use Moose 2;
use namespace::autoclean;

# the genotype codes below are based on the IUPAC ambiguity codes with the notable
#   exception of the indel codes that are specified in the snpfile specifications
# no type checks to avoid constraint checks at inclusion time
state $iupac = {
  A => 'A',
  C => 'C',
  G => 'G',
  T => 'T',
  D => '-',
  I => '+',
  R => 'AG',
  Y => 'CT',
  S => 'GC',
  W => 'AT',
  K => 'GT',
  M => 'AC',
  E => '-*',
  H => '+*'
};

has iupac => (
  is      => 'ro',
  traits  => ['Hash'],
  handles => {
    validGeno       => 'exists',
    deconvoluteGeno => 'get',
    getGeno         => 'get',   #fallback, in case semantic interpretation different
  },
  init_arg => undef,
  lazy     => 1,
  default => sub {$iupac},
);

# _buildIUPAC retruns a hashref of genotyping codes and corresponding nucleic
#   acid codes
#IUPAC also includes D => 'AGT', H => 'ACT', # may want to think about renaming D,H
#also includes V => 'ACG', B => 'CGT', do we want to include these?
#could remove * from E & H, but then we lose information on het vs homozygote
#shold we chose to check by length of genotype
#also thinking about benefit of including AA => A, CC => C, etc in _buildIUPAC
sub _buildIUPAC {
  return ;
}

#can also do this with ArrayRef and first_index, not sure which is faster
has hetGenos => (
  is      => 'ro',
  traits  => ['Hash'],
  isa => 'HashRef',
  handles => { isHet => 'exists' },
  lazy    => 1,
  default => sub { return {
    K => 1,
    M => 1,
    R => 1,
    S => 1,
    W => 1,
    Y => 1,
    E => 1,
    H => 1,
  } },
  init_arg => undef,
);

has homGenos => (
  is      => 'ro',
  isa => 'HashRef',
  traits  => ['Hash'],
  handles => { isHom => 'exists', },
  lazy    => 1,
  default => sub { return {
    A => 1,
    C => 1,
    G => 1,
    T => 1,
    D => 1,
    I => 1,
  } },
  init_arg => undef,
);

sub BUILD {
  # Trigger the lazy stuff, so that threads can get these memoized
  # $_[0] == $self
  $_[0]->getGeno('A'); $_[0]->isHet('A'); $_[0]->isHom('A');
}

#@param {Str} $geno1 : deconvoluted genotype, iupac geno, or another genotype-like string
#@param {Str} $geno2 : ""
sub hasGeno {
  #my ( $self, $geno1, $geno2 ) = @_;
  #$_[0] == $self
  #$_[1] == $geno1;
  #$_[2] == $geno2

  $_[0]->genosEqual( $_[1], $_[2] );

  goto &genosContained;
}

#extended equality check
sub genosEqual {
  #my ( $self, $geno1, $geno2 ) = @_;
  #$_[0] == $self
  #$_[1] == $geno1
  #$_[2] == $geno2

  if ( $_[1] eq $_[2] ) { return 1; }

  my $geno1deconv = $_[0]->iupac->{$_[1]};
  my $geno2deconv = $_[0]->iupac->{$_[2]};
  $_[1] = defined $geno1deconv ? $geno1deconv : $_[1];
  $_[2] = defined $geno2deconv ? $geno2deconv : $_[2];

  if ( $_[1] eq $_[2] ) {
    return 1;
  } # one could have been deconvoluted, and not the other

  #if the strings aren't equal, perhaps they're out of order
  my $matches = 0;
  for my $idx ( 0 ... length($_[1]) - 1 ) {
    $matches += index( $_[2], substr( $_[1], $idx, 1 ) ) > -1;
  }
  return $matches == length($_[1]) && $matches == length($_[2]);
}

sub genosContained {
  #my ( $self, $geno1, $geno2 ) = @_;
  #$_[1] == $geno1;
  #$_[2] == $geno2
  
  #geno1 is iupac or het, $geno2 is iupac or homozygote
  #~ flips a -1 to a 0 ; so ~something means something > -1
  if ( ~index( $_[1], $_[2] ) ) { return 1; }
  #geno2 ""
  if ( ~index( $_[2], $_[1] ) ) { return 1; }

  #in the case of E, and later maybe H, we may have -{Num} or +{Num}
  #leaving more flexible in case we later do {Num}- or {Num}+, say for neg strand
  #this could be abused however
  #check if genotype 1 and genotype 2 are indels
  #~ flips a -1 to a 0 ; so ~something means something > -1
  if ( index( $_[1], '-' ) > -1 && index( $_[2], '-' ) > -1 ) { return 1; }
  if ( index( $_[1], '+' ) > -1 && index( $_[2], '+' ) > -1 ) { return 1; }
}

#checks whether a genotype is a compound het
sub isCompoundHet {
  #my ( $self, $iupacGenotype, $referenceBase ) = @_;
  #$_[1] == $iupacGenotype;
  #$_[2] == $referenceBase;
  return index($_[0]->iupac->{ $_[1] }, $_[2]) == -1;
}

__PACKAGE__->meta->make_immutable;
1;
