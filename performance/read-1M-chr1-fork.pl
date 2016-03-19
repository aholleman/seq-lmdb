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
use Parallel::ForkManager;

my $reader = MockAnnotationClass->new();

my $pm = Parallel::ForkManager->new(6);

for my $thing (@{[1 .. 4]} ) {
  $pm->start and next;
  say 3.1e6 * $thing;
  say 4.1e6 * $thing;
    my $dataAref = $reader->dbRead('chr1', [3.1e6 * $thing..4.1e6 * $thing] );
  $pm->finish;
}
$pm->wait_all_children;


