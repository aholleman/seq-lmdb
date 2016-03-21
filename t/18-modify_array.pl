use strict;
use warnings;
use 5.10.0;

use DDP;
use List::Util qw(reduce);

use Test::More;
plan tests => 3;

my $aRef = [0,1,2,3,4,5];

my @arrCopy;

push @arrCopy, @$aRef;

my $newRef = [@$aRef];

for my $pos (@$aRef) {
  $pos *= 12;
}

my $sum = reduce { $a + $b } @arrCopy;

ok($sum == 15, 'push copies array contents');

$sum = reduce { $a + $b } @$aRef;

ok($sum = 178, 'modifying item found in array, in for loop modifies the original');

$sum = reduce { $a + $b } @$newRef;

p @$newRef;
ok($sum == 15, 'I know how to make new array references from a previous reference');