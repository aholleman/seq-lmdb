use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Cadd;

#A track whose features are only reported if they match the minor allele 
#present in the sample
#Called cadd because at the time of writing it's the 
use Mouse 2;
use namespace::autoclean;
use Seq::Tracks::Cadd::Order;
extends 'Seq::Tracks::Get';

state $order = Seq::Tracks::Cadd::Order->new();
$order = $order->order;

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

  # We may have stored an empty array at this position, in case 
  # the CADD scores read were not guaranteed to be sorted
  # Alternatively the CADD data for this position may be missing (not defined)
  if(!defined $_[1]->[ $_[0]->{_dbName} ] || !@{ $_[1]->[ $_[0]->{_dbName} ] } ) {
    return undef;
  }
  # Return undef for any allele that isn't defined for some reason
  # To preserve order with respect to alleles
  # if( !ref $altAlleles) { .. }
  if( !ref $_[5] ) {
    # if (defined $order->{ $refBase }{ $altAlleles } ) {
    if (defined $order->{ $_[4] }{ $_[5] } ) {
      #return $href->[ $self->dbName ]->[ $order->{ $refBase }{ $altAlleles } ]
      return $_[1]->[ $_[0]->{_dbName} ][ $order->{ $_[4] }{ $_[5] } ];
    } elsif ($_[5] < 0 || length($_[5]) > 1) {
      # If < 0 or length is > 1 it's an indel, return all records
      return $_[1]->[ $_[0]->{_dbName} ];
    }

    return undef;
  }

  # We optimize the most likely scenario (above), where we have only 1 allele
  # If multi-allelic, then return all alleles
  my @out;

  #for my $allele ( @{ $altAlleles } ) {
  for my $allele ( @{ $_[5] } ) {
    # https://ideone.com/ZBQzNC
    # if(defined $order->{ $refBase }{ $allele } ) {
    if(defined $order->{ $_[4] }{ $allele } ) {
      #push @out, $href->[ $self->dbName ]->[ $order->{ $refBase }->{ $allele } ];
      push @out, $_[1]->[ $_[0]->{_dbName} ][ $order->{ $_[4] }{ $allele } ];
      next;
    } elsif($allele < 0 || length($allele) > 1) {
      push @out, $_[1]->[ $_[0]->{_dbName} ];
      next;
    }
    push @out, undef;
  }
  
  return @out || undef;
}

__PACKAGE__->meta->make_immutable;
1;