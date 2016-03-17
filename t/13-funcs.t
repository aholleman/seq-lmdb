#!/usr/bin/perl
use 5.10.0;
use strict;
use warnings;

use Test::More;

plan tests => 1;

my %h = (
  'one' => {
    'two' => 'three',
    'four' => 'five',
  }
);

my ($x) = %h;

ok($x eq 'one', 'Hash in list context gives keys');