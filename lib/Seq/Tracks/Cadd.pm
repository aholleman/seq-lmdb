use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Cadd;

#A track whose features are only reported if they match the minor allele 
#present in the sample
#Called cadd because at the time of writing it's the 
use Moose;
use namespace::autoclean;
extends 'Seq::Tracks::Get';

use DDP;


#accepts $self, $dataHref, $chr (not used), $altAlleles
#@param <String|ArrayRef> $altAlleles : the alleles, like A,C,T,G or ['A','C','T','G'] 
sub get {
  state $order = {
    A => {
      C => 0,
      G => 1,
      T => 2,
    },
    C => {
      G => 0,
      T => 1,
      A => 2,
    },
    G => {
      T => 0,
      A => 1,
      C => 2,
    },
    T => {
      A => 0,
      C => 1,
      G => 2,
    }
  };

  state $dbName = $_[0]->dbName;

  state $tracks = Seq::Tracks::SingletonTracks->new();

  state $refTrack = $tracks->getRefTrackGetter();

  #my ($self, $href, $chr, $altAlleles) = @_;
  #==   $_[0], $_[1], $_[2], $_[3]
  # $altAlleles are the alleles present in the samples
  #ex A,G; ex2: A
  my $refBase = $refTrack->get($_[1]);

  if (!defined $order->{$refBase} ) {
    $_[0]->('warn', "reference base $refBase doesn't look valid, in Cadd.pm");
    
    return undef;
  }

  #note that if an allele doesn't have a defined value,
  #this will push an "undef" value in the array of CADD alleles
  #this is useful because we may want to know which CADD score belongs to 
  #which allele
  if( !ref $_[3] ) {
    if (defined $order->{ $refBase }->{ $_[3] } ) {
      return $_[1]->{ $dbName }->[ $order->{ $refBase }->{ $_[3] } ];
    }

    return undef;
  }

  say "couldn't find allele $_[3] under $refBase"; 
  p $_[1];
  p $_[3];
  #if we end up splitting the string, then we expect no whitespace around the 
  #alternative alleles
  return [ map { defined  $order->{ $refBase }->{ $_ } ? $_[1]->{ $dbName }->[ $order->{ $refBase }->{ $_ } ] : undef
    } @{ $_[3] } ]
  
}

__PACKAGE__->meta->make_immutable;
1;