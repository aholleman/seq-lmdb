use 5.10.0;
use warnings;
use strict;

package MockAnnotationClass;
use lib './lib';
use Moose;
use MooseX::Types::Path::Tiny qw/AbsDir/;
with 'Seq::Role::DBManager';


has database_dir => (
  is => 'ro',
  default =>  '/ssd/seqant_db_build/hg19_snp142/index_lmdb',
  isa => AbsDir,
  coerce => 1,
);

#__PACKAGE__->meta->
1;

package TestRead;
use DDP;

use Test::More;

plan tests => 16;

my $reader = MockAnnotationClass->new();

my $dataAref = $reader->dbRead('chr22', [20e6-1] );

#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO
ok($dataAref->[0]{ref} eq 'A', 'ref track ok in ~middle of chr22');

$dataAref = $reader->dbRead('chr22', [21e6-1] );

#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO
ok($dataAref->[0]{ref} eq 'T', 'ref track ok in intron of chr22');

$dataAref = $reader->dbRead('chr22', [0] );
ok($dataAref->[0]{ref} eq 'N', 'ref track ok at beginning of chr22');

$dataAref = $reader->dbRead('chr22', [51304565] );
ok($dataAref->[0]{ref} eq 'N', 'ref track ok at end of chr22');

$dataAref = $reader->dbRead('chr22', [40100000-1] );
ok($dataAref->[0]{ref} eq 'A', 'ref track ok at chr22:40100000');

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
$dataAref = $reader->dbRead('chr22', [16050001-1] );
ok($dataAref->[0]{phastCons} == 0.106, 'phastCons track ok at chr22:16050001');
p $dataAref;
$dataAref = $reader->dbRead('chr22', [16050001 + 8 -1] );
ok($dataAref->[0]{phastCons} == 0.055, "phastCons track ok at chr22:@{[16050001 + 8]}");
p $dataAref;

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

$dataAref = $reader->dbRead('chr22', [51239213 + 0 -1] );
ok($dataAref->[0]{phastCons} == 0.007, "phastCons track ok at chr22:@{[51239213 + 0]}");
p $dataAref;

$dataAref = $reader->dbRead('chr22', [51239213 + 6 -1] );
ok($dataAref->[0]{phastCons} == 0.042, "phastCons track ok at chr22:@{[51239213 + 6]}");
p $dataAref;

$dataAref = $reader->dbRead('chr22', [51239213 + 29 -1] );
ok($dataAref->[0]{phastCons} == 0.116, "phastCons track ok at chr22:@{[51239213 + 29]}");
p $dataAref;


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
$dataAref = $reader->dbRead('chr22', [16050001-1] );
ok($dataAref->[0]{phyloP} == 0.132, 'phyloP track ok at chr22:16050001');
p $dataAref;

$dataAref = $reader->dbRead('chr22', [16050001 + 2 -1] );
ok($dataAref->[0]{phyloP} == 0.114, "phyloP track ok at chr22:@{[16050001 + 2]}");
p $dataAref;

$dataAref = $reader->dbRead('chr22', [16050001 + 11 -1] );
ok($dataAref->[0]{phyloP} == -1.691, "phyloP track ok at chr22:@{[16050001 + 11]}");
p $dataAref;


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

$dataAref = $reader->dbRead('chr22', [51239213 + 0 -1] );
ok($dataAref->[0]{phyloP} == 0.065, "phyloP track ok at chr22:@{[51239213 + 0]}");
p $dataAref;

$dataAref = $reader->dbRead('chr22', [51239213 + 7 -1] );
ok($dataAref->[0]{phyloP} == 0.064, "phyloP track ok at chr22:@{[51239213 + 7]}");
p $dataAref;

$dataAref = $reader->dbRead('chr22', [51239213 + 22 -1] );
ok($dataAref->[0]{phyloP} == -1.937, "phyloP track ok at chr22:@{[51239213 + 22]}");
p $dataAref;
