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

state $refTrack;

sub BUILD {
  state $tracks = Seq::Tracks::SingletonTracks->new();

  $refTrack = $tracks->getRefTrackGetter();
} 
  
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
 
    if( defined $order->{ $refBase }->{ $_[3] } ) {
      return {
        $_[0]->name => $_[1]->{ $dbName }->[ $order->{ $refBase }->{ $_[3] } ]
      }
    } 
    
    #if we end up splitting the string, then we expect no whitespace around the 
    #alternative alleles
    return {
      $_[0]->name => [ map {
        defined  $order->{ $refBase }->{ $_ } ? $_[1]->{ $dbName }->[ $order->{ $refBase }->{ $_ } ] : undef
      } !ref $_[3] ? split ',', $_[3] : @{ $_[3] } ]
    }
    # foreach( ( $_[3] =~ m/[ACTG]/g ) ) {
    #   if( defined $order->{ $refBase }->{ $_[3] } ) {
    #     return {
    #       $_[0]->name => $_[1]->{ $dbName }->[ $order->{ $refBase }->{ $_[3] } ],
    #     }
    #   } 
    # }

  # foreach (split ( ",", $_[3] )) {
  #   say "for allele $_, cadd score is";
  #   p $_[1];
  #   p $_[1]->{ $dbName };
  #   p  $order->{ $refBase };
  #   p $order->{ $refBase }->{ $_ };
  #   p $_[1]->{ $dbName }->[ $order->{ $refBase }->{ $_ } ];
  # }
  # return {
  #   $_[0]->name => [ map {
  #     if(! defined $order->{ $refBase }->{ $_ } ) {
  #       $_[0]->log('warn', '$_ is not a valid allele; you may have included an extra')
  #     }
  #     defined $order->{ $refBase }->{ $_ } ? $_[1]->{ $dbName }->[ $order->{ $refBase }->{ $_ } ] : undef 
  #   } ! ref $_[3] ? split ( ",", $_[3] ) : $_[3] ]
    #translation:
    #$self->name => [ map { $href->{ $self->dbName }->[ $order->{ $refBase }->{ $_ } ] } !ref $altAlleles ? split ( ",", $altAlleles ) : $altAlleles ]
  #}

  # Same as:
  # my @out;
  # for my $allele (split (",", $altAlleles) ) {
  #   push @out, $href->{$self->dbName}->[ $order->{$refBase}->{$allele} ];

  #   #Note that the above will push undefined values, in order of the alleles
  #   #passed.
  #   #This is informative, since CADD scores don't exist for 'weird' alleles
  #   #like deletions or insertions
  #   #instead of:
  #   # if (defined $order->{$refBase}->{$allele} ) {
  #   #   push @out, $href->{$self->dbName}->[ $order->{$refBase}->{$allele} ];
  #   # }
  #   return {
  #     $self->name => \@out
  #   }
  # } 
}

__PACKAGE__->meta->make_immutable;
1;