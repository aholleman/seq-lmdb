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

plan tests => 1;

my $reader = MockAnnotationClass->new();

my $dataAref = $reader->dbRead('chr22', [20e6-1] );

#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO
ok($dataAref->[0]{ref} eq 'A', 'ref track ok in ~middle of chr22');

$dataAref = $reader->dbRead('chr22', [21e6-1] );

p $dataAref;
#UCSC: chr22:19,999,999 == ‘A' on hg19
#https://genome.ucsc.edu/cgi-bin/hgTracks?db=hg19&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A19999999%2D19999999&hgsid=481238143_ft2S6OLExhQ7NaXafgvW8CatDYhO
ok($dataAref->[0]{ref} eq 'T', 'ref track ok in ~middle of chr22');

$dataAref = $reader->dbRead('chr22', [0] );
ok($dataAref->[0]{ref} eq 'N', 'ref track ok at beginning of chr22');

$dataAref = $reader->dbRead('chr22', [51304565] );
ok($dataAref->[0]{ref} eq 'N', 'ref track ok at end of chr22');

$dataAref = $reader->dbRead('chr22', [40100000-1] );
ok($dataAref->[0]{ref} eq 'A', 'ref track ok at chr22:40100000');