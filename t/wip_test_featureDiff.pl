#!/usr/bin/perl
# your code goes here
use POSIX;
use Data::Dumper;

my @stuff = _diff(3, [0,1,2], [2,3,4], [4,5,6] );

print Dumper(\@stuff);

print join(',', @$stuff);

sub _diff {
  my $which = shift;
  my $b = 1;
  my %presence;

  foreach my $aRef (@_) {
      foreach(@$aRef) {
          $presence{$_} |= $b;
      }
  } continue {
      $b *= 2;
  }
  print Dumper(\%presence);
  $which = POSIX::floor($which == 1 ? $which : $which * $which/2 );
  return grep{ $presence{$_} == $which } keys %presence;
}