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

  ## finish
  #my ($self, $href, $chr, $altAlleles) = @_;
  #==   $_[0], $_[1], $_[2], $_[3]
  my $refBase = $refTrack->get($_[1]);

  if (!defined $order->{$refBase} ) {
    $_[0]->('warn', "got reference base $refBase, which doesn't look like valid, in Cadd.pm");
    return;
  }

  #note that if an allele doesn't have a defined value,
  #this will push an "undef" value in the array of CADD alleles
  #this is useful because we may want to know which CADD score belongs to 
  #which allele
  return {
    $_[0]->name => [ map { $_[1]->{ $_[0]->dbName }->[ $order->{ $refBase }->{ $_ } ] } split ( ",", $_[3] ) ]
    #translation:
    #$self->name => [ map { $href->{ $self->dbName }->[ $order->{ $refBase }->{ $_ } ] } split ( ",", $altAlleles ) ]
  }

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