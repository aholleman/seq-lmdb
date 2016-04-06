use strict;
use warnings;
use 5.10.0;

use DDP;
use List::Util qw(reduce);

my @arr1 = (0,1,2,3);
my @arr2 = (4,5,6);

my @range = $arr1[0] .. $arr2[2];

my @foo = reduce { $a . $b } @range;

p @foo;