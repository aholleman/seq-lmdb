use 5.10.0;
use warnings;
use strict;

package MockAnnotationClass;
use lib './lib';
use Mouse;
use MouseX::Types::Path::Tiny qw/AbsDir/;
with 'Seq::Role::DBManager';


has database_dir => (
  is => 'ro',
  default =>  '/ssd/seqant_db_build/hg19_snp142/index_lmdb',
  isa => AbsDir,
  coerce => 1,
);

#__PACKAGE__->meta->
1;

package TestWrite;
use DDP;

use Test::More;

plan tests => 1;

my $rw = MockAnnotationClass->new();

$rw->dbPatchBulk('chrFake', {0 => {ref => 'N'} } );

my $dataAref = $rw->dbRead('chrFake', [0] );

ok($dataAref->[0]{ref} eq 'N', '0th position in database ok');

p $dataAref;