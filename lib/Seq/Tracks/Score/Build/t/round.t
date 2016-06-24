use 5.10.0;
use strict;
use warnings;

use Seq::Tracks::Score::Build::Round;
use Test::More;

plan tests => 7;

my $number = 1;
my $number2 = -1;
my $number3 = 1.000;
my $number4 = 1.253;
my $number5 = 10.253;
my $number6 = -10.253;
my $number7 = -1.253;

my $rounder = Seq::Tracks::Score::Build::Round->new();

ok($rounder->roundToString($number) == 1);
ok($rounder->roundToString($number2) == -1);
ok($rounder->roundToString($number3) == 1);
ok($rounder->roundToString($number4) == 1.25);
ok($rounder->roundToString($number5) == 10.3);
ok($rounder->roundToString($number6) == -10.3);
ok($rounder->roundToString($number7) == -1.25);