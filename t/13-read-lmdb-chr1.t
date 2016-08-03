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
  { config =>'./config/hg19.lmdb.yml'}
);

my $refTrack = $tracks->singletonTracks->getRefTrackGetter();
my $snpTrack = $tracks->singletonTracks->getTrackGetterByName('snp146');
my $phyloPTrack = $tracks->singletonTracks->getTrackGetterByName('phyloP');
my $phastConsTrack = $tracks->singletonTracks->getTrackGetterByName('phastCons');
my $geneTrack = $tracks->singletonTracks->getTrackGetterByName('refSeq');
my $caddTrack = $tracks->singletonTracks->getTrackGetterByName('cadd');

my $trackData = $tracks->db->dbRead('chr1', 60523-1 );
my $refBase = $refTrack->get($trackData);
ok($refBase eq 'T', 'ref track ok @ chr1: 60523');
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 40370177 - 1 );
say "datahref is ";
p $trackData;

my $snpValHref = $snpTrack->get($trackData);
ok($snpValHref->{name} eq "rs564192510", "snp142 sparse track ok @ chr1:40370176");

$trackData = $tracks->db->dbRead('chr1', 40370426 - 1 );
say "datahref is ";
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 240e6 - 1 );
# $snpValHref = $snpTrack->get($trackData);

# ok($snpValHref->{name} eq 'rs368889620',
#   "deletion snp142 sparse track rs# ok at chr1:249240604-249240605 (0 indexed should be 249240604)");
say "datahref at 1-based 240e6 is ";
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 248e6 + 1 );
# $snpValHref = $snpTrack->get($trackData);

# ok($snpValHref->{name} eq 'rs368889620',
#   "deletion snp142 sparse track rs# ok at chr1:249240604-249240605 (0 indexed should be 249240604)");
say "datahref at 248e6 is ";
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 249240604 );
# $snpValHref = $snpTrack->get($trackData);

# ok($snpValHref->{name} eq 'rs368889620',
#   "deletion snp142 sparse track rs# ok at chr1:249240604-249240605 (0 indexed should be 249240604)");
say "datahref at 249240604 is ";
p $trackData;

$snpValHref = $snpTrack->get($trackData);

ok($snpValHref->{name} eq 'rs751090644',
  "deletion snp142 sparse track rs# ok at chr1:249240604-249240605 (0 indexed should be 249240604)");


$trackData = $tracks->db->dbRead('chr1', 249240606);
# $snpValHref = $snpTrack->get($trackData);

# ok(!defined $snpValHref,
#   "no snp142 sparse track exists beyond the end of the snp142 input text file,
#     which ends at chr1:249240604-249240605");
say "data aref at 249240606 is";
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 4252994 - 1);


$trackData = $tracks->db->dbRead('chr1', 10918);
say "data aref at 10918 is";
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 4252994 - 1);


$trackData = $tracks->db->dbRead('chr1', 232172500 - 1);
say "data aref at 232172500 is";
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 232172501 - 1);
say "data aref at 232172501 is";
p $trackData;

my $caddScore = $caddTrack->get($trackData, 'chr1', 232144787 - 1, 'C', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

$trackData = $tracks->db->dbRead('chr1', 232172409 - 1);
say "data aref at 232172409 is";
p $trackData;

$caddScore = $caddTrack->get($trackData, 'chr1', 232144787 - 1, 'C', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

$trackData = $tracks->db->dbRead('chr1', 232144609 - 1);
say "data aref at 232144609 is";
p $trackData;

$caddScore = $caddTrack->get($trackData, 'chr1', 232144787 - 1, 'C', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

$trackData = $tracks->db->dbRead('chr1', 232144610 - 1);
say "\ndata aref at 232144610 is";
p $trackData;

$caddScore = $caddTrack->get($trackData, 'chr1', 232144787 - 1, 'C', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

$trackData = $tracks->db->dbRead('chr1', 232144611 - 1);
say "\ndata aref at 232144611 is";
p $trackData;

$caddScore = $caddTrack->get($trackData, 'chr1', 232144787 - 1, 'C', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

say "\nfor position 1:232144787 C / T (stop Gained)";
$trackData = $tracks->db->dbRead('chr1', 232144787 - 1);
p $trackData;

$caddScore = $caddTrack->get($trackData, 'chr1', 232144787 - 1, 'C', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

say "\nfor position 1 BEFORE 1:232144787 C / T (stop Gained)";
$trackData = $tracks->db->dbRead('chr1', 232144786 - 1);
p $trackData;

$caddScore = $caddTrack->get($trackData, 'chr1', 232144786 - 1, 'A', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

say "\nfor position 1 AFTER 1:232144787 C / T (stop Gained)";
$trackData = $tracks->db->dbRead('chr1', 232144788 - 1);
p $trackData;

$caddScore = $caddTrack->get($trackData, 'chr1', 232144788 - 1, 'A', 'T');
say "CADD score, assuming a T allele: " . $caddScore;

$trackData = $tracks->db->dbRead('chr1', 249240621 - 1);
say "trackData for last CADD-containing base for chr1 is";
p $trackData;

$trackData = $tracks->db->dbRead('chr1', 97564155 - 1);
say "trackData for chr1:97564154";
p $trackData;

