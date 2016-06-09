use 5.10.0;
use warnings;
use strict;

package MockAnnotationClass;
use lib './lib';
use Moose;
use MooseX::Types::Path::Tiny qw/AbsDir/;
extends 'Seq::Tracks';
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

my $refTrack = $tracks->singletonTracks->getRefTrackGetter();
my $snpTrack = $tracks->singletonTracks->getTrackGetterByName('snp142');
my $phyloPTrack = $tracks->singletonTracks->getTrackGetterByName('phyloP');
my $phastConsTrack = $tracks->singletonTracks->getTrackGetterByName('phastCons');
my $geneTrack = $tracks->singletonTracks->getTrackGetterByName('refSeq');
p $refTrack;
p $snpTrack;
p $phyloPTrack;
p $phastConsTrack;
p $geneTrack;

my $dataAref = $tracks->dbRead('chr1', 60523-1 );
my $refBase = $refTrack->get($dataAref);
ok($refBase eq 'T', 'ref track ok @ chr1: 60523');
p $dataAref;

$dataAref = $tracks->dbRead('chr1', 40370177 - 1 );
say "datahref is ";
p $dataAref;

my $snpValHref = $snpTrack->get($dataAref);
ok($snpValHref->{name} eq "rs564192510", "snp142 sparse track ok @ chr1:40370176");

$dataAref = $tracks->dbRead('chr1', 40370426 - 1 );
say "datahref is ";
p $dataAref;

$dataAref = $tracks->dbRead('chr1', 249240605 - 1 );
$snpValHref = $snpTrack->get($dataAref);

ok($snpValHref->{name} eq 'rs368889620',
  "deletion snp142 sparse track rs# ok at chr1:249240604-249240605 (0 indexed should be 249240604)");
p $dataAref;

$dataAref = $tracks->dbRead('chr1', 249240605 );
$snpValHref = $snpTrack->get($dataAref);

ok(!defined $snpValHref,
  "no snp142 sparse track exists beyond the end of the snp142 input text file,
    which ends at chr1:249240604-249240605");
p $dataAref;

$dataAref = $tracks->dbRead('chr1', 4252994 - 1);


$dataAref = $tracks->dbRead('chr1', 10918);
p $dataAref;