use 5.10.0;
use strict;
use warnings;

my $str = 'A,G';

use Benchmark qw(:all) ;

cmpthese(1e7, {
  'Index' => sub { 
    if(index($str, ',') > -1) { 
      my @stuff = split(',', $str); 
      return \@stuff;
    } 
    return $str;
  },
  'Split_only' => sub { 
    my @stuff = split(',', $str);

    if(@stuff == 1) { 
      return $stuff[0];
    } 

    return \@stuff;
  },
  'Length' => sub { 
    if(length($str) > 1) { 
      my @stuff = split(',', $str); 

      if(@stuff = 1) {
        return $stuff[0];
      }
      return \@stuff; 
    }
    return $str; 
  },
});
