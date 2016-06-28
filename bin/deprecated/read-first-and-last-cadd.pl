use 5.10.0;
use strict;
use warnings;

open(my $fh, "-|", "zcat $ARGV[0]");
my $chr = $ARGV[1];

say "reading file $ARGV[0] for $ARGV[1]!";

my $hadFound;
while(<$fh>) {
  if( substr($_, 0, index($_, "\t") ) eq $chr ) { #249e6 * 2
    if(!$hadFound) {
      say "First line: $_";
    }

    $hadFound = 1;

  } else {
    if($hadFound) {
      say "Last line: $_";
      last;
    }
  }
}