use 5.10.0;
use strict;
use warnings;
package Testing;

use Test::More;
use DDP;

plan tests => 13;

use Seq::Tracks::Gene::Site;

my $siteHandler = Seq::Tracks::Gene::Site->new();

my $packedData = $siteHandler->packCodon(
  ('Intronic', '-')
);

my $unpackedData = $siteHandler->unpackCodon($packedData);

ok($unpackedData->{$siteHandler->siteTypeKey} eq 'Intronic', 'reads site type ok from shortened site');
ok($unpackedData->{$siteHandler->strandKey} eq '-', 'reads strand ok from shortened site');
ok(!defined $unpackedData->{$siteHandler->codonNumberKey}, 'reads codon number ok from shortened site');
ok(!defined $unpackedData->{$siteHandler->codonPositionKey}, 'reads codon position ok from shortened site');
ok(!defined $unpackedData->{$siteHandler->codonSequenceKey}, 'reads codon position ok from shortened site');
ok(scalar keys %$unpackedData == 5, 'shortened site has 5 keys');

p $unpackedData;

$packedData = $siteHandler->packCodon(
  ('Coding', '+')
);

$unpackedData = $siteHandler->unpackCodon($packedData);

ok($unpackedData->{$siteHandler->siteTypeKey} eq 'Coding', 'site type ok from 2nd shortened site');
ok($unpackedData->{$siteHandler->strandKey} eq '+', 'reads strand ok from 2nd shortened site');

p $unpackedData;

$packedData = $siteHandler->packCodon(
  ('Coding', '+', 1, 2, 'ATG')
);

$unpackedData = $siteHandler->unpackCodon($packedData);

ok($unpackedData->{$siteHandler->siteTypeKey} eq 'Coding', 'site type ok from full site');
ok($unpackedData->{$siteHandler->strandKey} eq '+', 'reads strand ok from full site');
ok($unpackedData->{$siteHandler->codonNumberKey} == 1, 'reads codon number ok from full site');
ok($unpackedData->{$siteHandler->codonPositionKey} == 2, 'reads codon position ok from full site');
ok($unpackedData->{$siteHandler->codonSequenceKey} eq 'ATG', 'reads codon position ok from full site');

p $unpackedData;