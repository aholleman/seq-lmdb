use strict;
use warnings;
use 5.10.0;

use DDP;
use List::Util qw(reduce);

my $string = 'hellow'; #6 characters

if ($string % 3) {
  print "Modulo didn't work"
}

$string .= 'o';

if ($string % 3) {
  print "Modulo worked, with $_";
}