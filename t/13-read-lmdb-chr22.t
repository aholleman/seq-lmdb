use 5.10.0;
use warnings;
use strict;

package MockAnnotationClass;
use lib './lib';
use Mouse;
use Types::Path::Tiny qw/AbsDir/;

extends 'Seq::Base';

use Seq::Tracks;

has tracks => ( is => 'ro', required => 1);
has database_dir => ( is => 'ro', required => 1);

has singletonTracks => ( is => 'ro', init_arg => undef, lazy => 1, default => sub{
  my $self = shift; 
  return Seq::Tracks->new({gettersOnly => 1, tracks => $self->tracks});
});

has db => (is => 'ro', writer => '_setDb');
sub BUILD {
  my $self = shift;
  $self->_setDb( Seq::DBManager->new({database_dir => $self->database_dir}) );
}
#__PACKAGE__->meta->
1;

package TestRead;
use DDP;

use Test::More;
use List::Util qw/reduce/;

use Seq::Tracks::Score::Build::Round;

my $rounder = Seq::Tracks::Score::Build::Round->new();

plan tests => 27;

my $tracks = MockAnnotationClass->new_with_config(
  { config =>'./config/hg19.lmdb_test.yml'}
);

say "tracks are";
p $tracks->singletonTracks;

my $refTrack = $tracks->singletonTracks->getRefTrackGetter();
my $snpTrack = $tracks->singletonTracks->getTrackGetterByName('snp146');
my $phyloPTrack = $tracks->singletonTracks->getTrackGetterByName('phyloP');
my $phastConsTrack = $tracks->singletonTracks->getTrackGetterByName('phastCons');
my $geneTrack = $tracks->singletonTracks->getTrackGetterByName('refSeq');
p $refTrack;
p $snpTrack;
p $phyloPTrack;
p $phastConsTrack;
p $geneTrack;

my $dataAref = $tracks->db->dbRead('chr22', 20e6-1 );

my $db1 = $tracks->db;
my $db2 = $tracks->db;

say "is $db1 == $db2? " . ($db1 == $db2 ? "YES" : "NO");

#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO

my $refBase = $refTrack->get($dataAref);
ok($refBase eq 'A', 'ref track ok in ~middle of chr22');
p $dataAref;

#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO
$dataAref = $tracks->db->dbRead('chr22', 21e6-1 );
$refBase = $refTrack->get($dataAref);
p $dataAref;
ok($refBase eq 'T', 'ref track ok in intron of chr22');

$dataAref = $tracks->db->dbRead('chr22', 0 );
$refBase = $refTrack->get($dataAref);
p $dataAref;
ok($refBase eq 'N', 'ref track ok at beginning of chr22');

$dataAref = $tracks->db->dbRead('chr22', 51304565 );
$refBase = $refTrack->get($dataAref);
p $dataAref;
ok($refBase eq 'N', 'ref track ok at end of chr22');

$dataAref = $tracks->db->dbRead('chr22', 40100000-1 );
$refBase = $refTrack->get($dataAref);
p $dataAref;
ok($refBase eq 'A', 'ref track ok at chr22:40100000');

#phastCons testing
#first header entry
#fixedStep chrom=chr22 start=16050001 step=1 
#choose 9th entry
# 0.106 # this should be 16050001 ; when 0 indexed 16050000
# 0.099
# 0.092
# 0.084
# 0.075
# 0.066
# 0.056
# 0.056
# 0.055 # this should be 16050001 + 8, or +7 when 0 indexed = 16050008
$dataAref = $tracks->db->dbRead('chr22', 16050001-1 );
my $phastConsVal = $phastConsTrack->get($dataAref);
p $dataAref;
say "phastConsVal is";
p $phastConsVal;
ok($phastConsVal == $rounder->round(0.106), 'phastCons track ok at chr22:16050001');

$dataAref = $tracks->db->dbRead('chr22', 16050001 + 1 -1 );
$phastConsVal = $phastConsTrack->get($dataAref);
p $dataAref;
say "phastConsVal is";
p $phastConsVal;
ok($phastConsVal == $rounder->round(0.099), 'phastCons track ok at chr22:16050001');

$dataAref = $tracks->db->dbRead('chr22', 16050001 + 8 -1 );
$phastConsVal = $phastConsTrack->get($dataAref);
p $dataAref;
say "phastConsVal is";
p $phastConsVal;
ok($phastConsVal == $rounder->round(0.055), "phastCons track ok at chr22:@{[16050001 + 8]}");


#last header entry (tail -n 10000)
#fixedStep chrom=chr22 start=51239213 step=1
# 0.007 #1st (+0)
# 0.014 #+1
# 0.020 #+2
# 0.026 #+3
# 0.032 #+4
# 0.037 #+5
# 0.042 #+6
# 0.046 #+7
# 0.050 #+8
# 0.053 #+9
# 0.057 #+10
# 0.059 #+11
# 0.062
# 0.064
# 0.066
# 0.067
# 0.068
# 0.068
# 0.068
# 0.068
# 0.068
# 0.067
# 0.065
# 0.073
# 0.081
# 0.089
# 0.096
# 0.103
# 0.109
# 0.116 #+29

$dataAref = $tracks->db->dbRead('chr22', 51239213 + 0 -1 );
$phastConsVal = $phastConsTrack->get($dataAref);
p $dataAref;
say "phastConsVal is";
p $phastConsVal;
ok($phastConsVal == $rounder->round(0.007), "phastCons track ok at chr22:@{[51239213 + 0]}");

$dataAref = $tracks->db->dbRead('chr22', 51239213 + 6 -1 );
$phastConsVal = $phastConsTrack->get($dataAref);
p $dataAref;
say "phastConsVal is";
p $phastConsVal;
ok($phastConsVal == $rounder->round(0.042), "phastCons track ok at chr22:@{[51239213 + 6]}");

$dataAref = $tracks->db->dbRead('chr22', 51239213 + 29 -1 );
$phastConsVal = $phastConsTrack->get($dataAref);
p $dataAref;
say "phastConsVal is";
p $phastConsVal;
ok($phastConsVal == $rounder->round(0.116), "phastCons track ok at chr22:@{[51239213 + 29]}");


#phyloP testing
#first entry
#fixedStep chrom=chr22 start=16050001 step=1
# 0.132
# 0.127
# 0.114
# 0.113
# 0.114
# 0.132
# -1.403
# 0.114
# 0.127
# 0.127
# 0.132
# -1.691

#choose first, third and last
$dataAref = $tracks->db->dbRead('chr22', 16050001-1 );
my $phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
ok($phyloPval == $rounder->round(0.132), 'phyloP track ok at chr22:16050001');

$dataAref = $tracks->db->dbRead('chr22', 16050001 + 1 -1 );
$phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
ok($phyloPval == $rounder->round(0.127), 'phyloP track ok at chr22:16050001');

$dataAref = $tracks->db->dbRead('chr22', 16050001 + 2 -1 );
$phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
say "phyloP is";
p $phyloPval;
ok($phyloPval == $rounder->round(0.114), "phyloP track ok at chr22:@{[16050001 + 2]}");

$dataAref = $tracks->db->dbRead('chr22', 16050001 + 11 -1 );
$phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
say "phyloP is";
p $phyloPval;
ok($phyloPval == $rounder->round(-1.691), "phyloP track ok at chr22:@{[16050001 + 11]}");

#now testing entries after the last header
#fixedStep chrom=chr22 start=51239213 step=1
# 0.065
# 0.072
# 0.075
# 0.072
# 0.064
# 0.072
# 0.065
# 0.064
# 0.065
# 0.072
# 0.064
# 0.065
# 0.065
# 0.075
# 0.072
# 0.064
# 0.065
# 0.075
# 0.075
# 0.072
# 0.065
# 0.065
# -1.937

$dataAref = $tracks->db->dbRead('chr22', 51239213 + 0 -1 );
$phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
ok($phyloPval == $rounder->round(0.065), "phyloP track ok at chr22:@{[51239213 + 0]}");

$dataAref = $tracks->db->dbRead('chr22', 51239213 + 7 -1 );
$phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
ok($phyloPval == $rounder->round(0.064), "phyloP track ok at chr22:@{[51239213 + 7]}");

$dataAref = $tracks->db->dbRead('chr22', 51239213 + 22 -1 );
$phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
ok($phyloPval == $rounder->round(-1.937), "phyloP track ok at chr22:@{[51239213 + 22 - 1]}");

#now testing sparse track (with snp142)
$dataAref = $tracks->db->dbRead('chr22', 51239213 + 22 -1 );
$phyloPval = $phyloPTrack->get($dataAref);
p $dataAref;
ok($phyloPval == $rounder->round(-1.937), "phyloP track ok at chr22:@{[51239213 + 22 - 1]}");


$dataAref = $tracks->db->dbRead('chr22', 51244031 - 1);
$phyloPval = $phyloPTrack->get($dataAref);
say "showing data for 51244032";
p $dataAref;
ok($phyloPval == $rounder->round(.104), "phyloP track ok at chr22:51244032 (last phyloP entry)");
##snp testing
say "Starting snp testing";
$dataAref = $tracks->db->dbRead('chr22', 16050074);
p $dataAref;

my $snpValHref = $snpTrack->get($dataAref);

say "snpValHref";
p $snpValHref;
my $rsNumber = $snpValHref->{name};
ok($rsNumber eq 'rs587697622', "snp142 sparse track ok at chr22:16050074");

$dataAref = $tracks->db->dbRead('chr22', 16112390 );
$snpValHref = $snpTrack->get($dataAref);
p $dataAref;
say "snpValHref is";
p $snpValHref;
$rsNumber = $snpValHref->{name};
ok($rsNumber eq 'rs2844929', "snp142 sparse track ok at chr22:16112390");

#test an indel
$dataAref = $tracks->db->dbRead('chr22', [16140742 .. 16140746 - 1] );
my $snpValAref;

#4 long
for my $data (@$dataAref) {
  $snpValHref = $snpTrack->get($data);
  my $rsNumber = $snpValHref->{name};
  ok($rsNumber eq 'rs577706315', "snp142 sparse track ok at the indel chr22:16140742 .. 16140746");
}

#end of chr22 snp142 file
$dataAref = $tracks->db->dbRead('chr22', 51244514);
$snpValHref = $snpTrack->get($dataAref);
$rsNumber = $snpValHref->{name};
say "showing data for chr22:51244514";
p $dataAref;
ok($rsNumber eq 'rs202006767', "snp142 sparse track ok at chr22:51244514 (end)");

$dataAref = $tracks->db->dbRead('chr22', 51244515 );
$snpValHref = $snpTrack->get($dataAref);
p $dataAref;
ok(!defined $snpValHref->{name}, "snp142 sparse track doesn't exist past at chr22:51244514");

#insertion in snp142 file, chromStart == chromEnd
$dataAref = $tracks->db->dbRead('chr22', 22452926 );
$snpValHref = $snpTrack->get($dataAref);
$rsNumber = $snpValHref->{name};
p $dataAref;
ok($rsNumber eq 'rs148698006', "snp142 sparse track ok at chr22:22452926");

my $dataHref = $tracks->db->dbRead('chr22', 29445184 - 1 );

say "dataHref is";
p $dataHref;
#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO
my $geneTrackData = $geneTrack->get($dataHref, 'chr22');
say "geneTrack data is";
p $geneTrackData;

my $geneSymbol = reduce { $a eq $b ? $a : $b } @{$geneTrackData->{geneSymbol} };
ok($geneSymbol eq 'ZNRF3', 'geneSymbol correct (ZNRF3)');

say "Checking -1";
my $dataHref = $tracks->db->dbRead('chr3', -1 );

say "dataHref is";
p $dataHref;

# $dataAref = $tracks->db->dbRead('chr1', 60523-1 );
# $refBase = $refTrack->get($dataAref);
# ok($refBase eq 'T', 'ref track ok @ chr1: 60523');
# p $dataAref;

# $dataHref = $tracks->db->dbRead('chr1', 40370176 - 1 );
# say "datahref is ";
# p $dataHref;
# $snpValHref = $snpTrack->get($dataHref);
# ok($snpValHref->{name} eq "rs564192510", "snp142 sparse track ok @ chr1:40370176");

# $dataHref = $tracks->db->dbRead('chr1', 40370426 - 1 );
# say "datahref is ";
# p $dataHref;
# $snpValHref = $snpTrack->get($dataHref);
# ok($snpValHref->{name} eq "rs564192510", "snp142 sparse track ok @ chr1:40370426");
#testing snp142 track and chr1
#it has 4477.000000,531.000000 alleleNs
# $dataAref = $tracks->db->dbRead('chr1', [40370176] );
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

# $dataAref = $tracks->db->dbRead('chr1', [249240604] );
# ok($dataAref->[0]{4}{0} eq 'rs368889620',
#   "insertion snp142 sparse track rs# ok at chr1:249240604-249240605 (0 indexed should be 249240604)");
# p $dataAref;

# $dataAref = $tracks->db->dbRead('chr1', [249240605] );
# ok(!defined $dataAref->[0]{4},
#   "no snp142 sparse track exists beyond the end of the snp142 input text file,
#     which ends at chr1:249240604-249240605");
# p $dataAref;
