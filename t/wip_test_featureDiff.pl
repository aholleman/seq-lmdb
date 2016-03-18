#!/usr/bin/env perl
# http://www.perlmonks.org/?node_id=919422
use 5.10.0;
use strict;
use warnings;

use POSIX;

my $aref1 = [0,1,2,3,4];
my $aref2 = [3, 4, 5, 6];
my $aref3 = [5,6,7,8];

sub _featureDiff {
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
  $which = POSIX::floor($which == 1 ? $which : $which * 2);
  return grep{ $presence{$_} == $which } keys %presence;
}

print join( ',', _featureDiff(1, $aref1, $aref2, $aref3) );
print "\n";
print join( ',', _featureDiff(2, $aref1, $aref2, $aref3) );
print "\n";
print join( ',', _featureDiff(3, $aref1, $aref2, $aref3) );