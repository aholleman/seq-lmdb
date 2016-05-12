use 5.10.0;
use warnings;
use strict;

package MockAnnotationClass;
use lib './lib';
use Moose;
use MooseX::Types::Path::Tiny qw/AbsDir/;
extends 'Seq::Base';
with 'Seq::Role::DBManager';

#__PACKAGE__->meta->
1;

package TestRead;
use DDP;

use Test::More;
use List::Util qw/reduce/;
plan tests => 4;

my $tracks = MockAnnotationClass->new_with_config(
  { configfile =>'./config/hg19.lmdb.yml'}
);

my $geneTrack = $tracks->getTrackGetterByName('refSeq');

p $geneTrack;

my $dataHref = $tracks->dbRead('chr22', 29445184  - 1);

say "dataHref is";
p $dataHref;
#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO
my $geneTrackData = $geneTrack->get($dataHref, 'chr22');
say "geneTrack data is";
p $geneTrackData;

my $geneSymbol = reduce { $a eq $b ? $a : $b } @{$geneTrackData->{geneSymbol} };
ok($geneSymbol eq 'ZNRF3', 'geneSymbol correct');
ok($geneTrackData->{regionType} eq 'Intronic', 'reads Intronic entry ok');


$dataHref = $tracks->dbRead('chr22', 1 - 1 );
say "dataHref is";
p $dataHref;
$geneTrackData = $geneTrack->get($dataHref, 'chr22');
say "geneTrack data is";
p $geneTrackData;
ok($geneTrackData->{regionType} eq 'Intergenic', 'reads Intergenic entry ok');


$dataHref = $tracks->dbRead('chr22', 29445184 + 100 );
say "dataHref is";
p $dataHref;
$geneTrackData = $geneTrack->get($dataHref, 'chr22');
say "geneTrack data is";
p $geneTrackData;

ok($geneTrackData->{regionType} eq 'Exonic', 'reads exonic entry ok');

$dataHref = $tracks->dbRead('chr22', 29445184 + 103 );
say "dataHref is";
p $dataHref;
$geneTrackData = $geneTrack->get($dataHref, 'chr22');
say "geneTrack data is";
p $geneTrackData;


# $dataHref = $tracks->dbRead('chrY', 16634487  - 1);

# $geneTrackData = $geneTrack->get($dataHref, 'chrY');
# say "geneTrack data is";
# p $geneTrackData;
# ok($geneTrackData->{geneSymbol} eq 'AY358562', 'reads AY358562 entry ok');


# $dataHref = $tracks->dbRead('chrY', 16955848  - 1);

# $geneTrackData = $geneTrack->get($dataHref, 'chrY');
# say "geneTrack data is";
# p $geneTrackData;
# ok($geneTrackData->{geneSymbol} eq 'AY358562', 'reads AY358562 entry ok');

# $dataHref = $tracks->dbRead('chrY', 1  - 1);

# $geneTrackData = $geneTrack->get($dataHref, 'chrY');
# say "geneTrack data is";
# p $geneTrackData;
# ok($geneTrackData->{geneSymbol} eq 'AY358562', 'reads AY358562 entry ok');
#testing snp142 track and chr1
#it has 4477.000000,531.000000 alleleNs
# $dataAref = $tracks->dbRead('chr1', [40370176] );
# ok($dataAref->[0]{4}{0} eq 'rs564192510', "insertion snp142 sparse track rs# ok at chr1:22452926");
# p $dataAref;

# my @values = @{ $dataAref->[0]{4}{7} };
# ok($values[0] + $values[1] == 4477.000000 + 531.000000,
#   "insertion snp142 sparse track has the right total allele count at chr1:22452926");
# ok($values[0] = 4477.000000, 
#   "insertion snp142 sparse track has the right minor allele count at chr1:22452926");
# ok($values[1] = 531.000000, 
#   "insertion snp142 sparse track has the right major allele count at chr1:22452926");
# p $dataAref;

# $dataAref = $tracks->dbRead('chr1', [249240604] );
# ok($dataAref->[0]{4}{0} eq 'rs368889620',
#   "insertion snp142 sparse track rs# ok at chr1:249240604-249240605 (0 indexed should be 249240604)");
# p $dataAref;

# $dataAref = $tracks->dbRead('chr1', [249240605] );
# ok(!defined $dataAref->[0]{4},
#   "no snp142 sparse track exists beyond the end of the snp142 input text file,
#     which ends at chr1:249240604-249240605");
# p $dataAref;
