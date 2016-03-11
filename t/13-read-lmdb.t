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

my $dataAref = $reader->dbRead('chr22', [20e6 .. 21e6] );

#p $dataAref;