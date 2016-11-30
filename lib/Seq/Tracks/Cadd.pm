use 5.10.0;
use strict;
use warnings;

# TODO: refactor to allow mutliple alleles, and multiple posiitions
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
  #my ($self, $href, $chr, $refBase, $altAlleles, $outAccum, $alleleNumber) = @_
  # $_[0] == $self
  # $_[1] == $href
  # $_[2] == $chr
  # $_[3] == $refBase
  # $_[4] == $altAlleles
  # $_[5] == $alleleIdx
  # $_[6] == $positionIdx
  # $_[7] == $outAccum

  if (!defined $order->{$_[3]} ) {
    # $self->log
    $_[0]->log('warn', "reference base $_[3] doesn't look valid, in Cadd.pm");
    
    # Eplicitly return undef as a value, this is what our program treats as missing data
    # Returning nothing is not the same, in list context
    if($_[7]) {
      $_[7][$_[5]][$_[6]] = undef;

      return $_[7];
    }

    return undef
  }

  # We may have stored an empty array at this position, in case 
  # the CADD scores read were not guaranteed to be sorted
  # Alternatively the CADD data for this position may be missing (not defined)
  if( !defined $_[1]->[$_[0]->{_dbName}] || !@{$_[1]->[$_[0]->{_dbName}]} ) {
    if($_[7]) {
      $_[7][$_[5]][$_[6]] = undef;

      return $_[7];
    }

    return undef;
  }
  
  # if (defined $order->{ $refBase }{ $altAlleles } ) {
  if ( defined $order->{$_[3]}{$_[4]} ) {
    #return $href->[ $self->dbName ]->[ $order->{ $refBase }{ $altAlleles } ]
    if($_[7]) {
      $_[7][$_[5]][$_[6]] = $_[1]->[$_[0]->{_dbName}][ $order->{$_[3]}{$_[4]} ];

      return $_[7];
    }

    return $_[1]->[$_[0]->{_dbName}][ $order->{$_[3]}{$_[4]} ];
  }

  # For indels, which will be the least frequent, return it all
  if (length( $_[4] ) > 1) {
    if($_[7]) {
       $_[7][$_[5]][$_[6]] = $_[1]->[ $_[0]->{_dbName} ];

       return $_[7];
    }
    return $_[1]->[ $_[0]->{_dbName} ];
  }

  # Allele isn't an indel, but isn't found
  if ($_[7]) {
    $_[7][$_[5]][$_[6]] = undef;

    return $_[7];
  }

  return  undef;
}

# sub getIndel {
#   #my ($self, $href, $chr, $position, $refBase, $altAlleles) = @_
#   # $_[0] == $self
#   # $_[1] == $href
#   # $_[2] == $chr
#   # $_[3] == $refBase
#   # $_[4] == $altAlleles

#   # if (!defined $order->{ $refBase} )
#   if (!defined $order->{ $_[3] } ) {
#     # $self->log
#     $_[0]->log('warn', "reference base $_[3] doesn't look valid, in Cadd.pm");
    
#     # Eplicitly return undef as a value, this is what our program treats as missing data
#     # Returning nothing is not the same, in list context
#     return undef;
#   }

#   # We may have stored an empty array at this position, in case 
#   # the CADD scores read were not guaranteed to be sorted
#   # Alternatively the CADD data for this position may be missing (not defined)
#   if(!defined $_[1]->[ $_[0]->{_dbName} ] || !@{ $_[1]->[ $_[0]->{_dbName} ] } ) {
#     return undef;
#   }

#   #for my $allele ( @{ $altAlleles } ) {
#   for my $allele ( @{ $_[4] } ) {
#     # https://ideone.com/ZBQzNC
#     # if(defined $order->{ $refBase }{ $allele } ) {
#     if(defined $order->{ $_[3] }{ $allele } ) {
#       #push @out, $href->[ $self->dbName ]->[ $order->{ $refBase }->{ $allele } ];
#       push @out, $_[1]->[ $_[0]->{_dbName} ][ $order->{ $_[3] }{ $allele } ];
#       next;
#     }
#     # TODO: either re-enable for use the existing interface to handle indels
#     # by passing all possible alleles
#     # elsif(length($allele) > 1) {
#     #   push @out, $_[1]->[ $_[0]->{_dbName} ];
#     #   next;
#     # }
#     push @out, undef;
#   }
  
#   return @out ? join(';', @out) : undef;
# }

__PACKAGE__->meta->make_immutable;
1;