use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Cadd;

#A track whose features are only reported if they match the minor allele 
#present in the sample
#Called cadd because at the time of writing it's the 
use Mouse 2;
use namespace::autoclean;
extends 'Seq::Tracks::Get';

state $order = {
  A => {
    C => 0,
    G => 1,
    T => 2,
  },
  C => {
    A => 0,
    G => 1,
    T => 2,
  },
  G => {
    A => 0,
    C => 1,
    T => 2,
  },
  T => {
    A => 0,
    C => 1,
    G => 2,
  }
};

#accepts $self, $dataHref, $chr (not used), $altAlleles
#@param <String|ArrayRef> $altAlleles : the alleles, like A,C,T,G or ['A','C','T','G'] 
sub get {
  #my ($self, $href, $chr, $position, $refBase, $altAlleles) = @_
  # $_[0] == $self
  # $_[1] == $href
  # $_[4] == $refBase
  # $_[5] == $altAlleles

  # if (!defined $order->{ $refBase} )
  if (!defined $order->{ $_[4] } ) {
    # $self->log
    $_[0]->log('warn', "reference base $_[4] doesn't look valid, in Cadd.pm");
    
    # Eplicitly return undef as a value, this is what our program treats as missing data
    # Returning nothing is not the same, in list context
    return undef;
  }

  # Return undef for any allele that isn't defined for some reason
  # To preserve order with respect to alleles
  # if( !ref $altAlleles) { .. }
  if( !ref $_[5] ) {
    # if (defined $order->{ $refBase }{ $altAlleles } ) {
    if (defined $order->{ $_[4] }{ $_[5] } ) {
      #return $href->[ $self->dbName ]->[ $order->{ $refBase }{ $altAlleles } ]
      return $_[1]->[$_[0]->dbName][ $order->{ $_[4] }{ $_[5] } ];
    }

    return undef;
  }

  # We optimize the most likely scenario (above), where we have only 1 allele
  # If multi-allelic, then return all alleles
  my @out;

  #for my $allele ( @{ $altAlleles } ) {
  for my $allele ( @{ $_[5] } ) {
    # if($allele ne $refBase) {
    if($allele ne $_[4]) {
      # https://ideone.com/ZBQzNC
      # if(defined $order->{ $refBase }{ $allele } ) {
      if(defined $order->{ $_[4] }{ $allele } ) {
        #push @out, $href->[ $self->dbName ]->[ $order->{ $refBase }->{ $allele } ];
        push @out, $_[1]->[$_[0]->dbName][ $order->{ $_[4] }{ $allele } ];
        next;
      }
      push @out, undef;
    }
  }
  
  return @out || undef;
}

__PACKAGE__->meta->make_immutable;
1;