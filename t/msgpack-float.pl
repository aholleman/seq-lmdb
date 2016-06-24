use 5.10.0;
use strict;
use warnings;

use Test::More;
use DDP;

plan tests => 1;
use Data::MessagePack;

my $mp = Data::MessagePack->new();
$mp->prefer_integer();

my $float =  sprintf("%0.2f", -3.563);
say "float is $float";

my $packed = $mp->pack($float );
say "float is, and takes " . length($packed) . " bytes";
p $packed;

my $float2 =  "".3.56;

my $packed2 = $mp->pack({0 => $float2});

say "float 2 is, and takes " . length($packed2) . " bytes";
p $packed2;

my @array = ($float, "60.1");

my $packed3 = $mp->pack(\@array);

say "packed is";
p $packed;
say "length of packed is";
my $length = length($packed);
p $length;

say "packed2 is";
p $packed2;
say "length of packed2 is";
$length = length($packed2);
p $length;

say "packed3 is";
p $packed3;

# say "packed 3 is";
# p $packed2;

$float=  "". -0.24;

$packed2 = $mp->pack($float);

say "-0.24 stored as";
p $packed2;

say "length of -0.24 is : " . length($packed2) . " bytes";

$float=  "".-2.24;

$packed2 = $mp->pack($float);

say "-2.243 stored as";
p $packed2;

say "length of -2.243 is : " . length($packed2) . " bytes";