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
use List::MoreUtils qw/first_index/;

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
p $refTrack;
p $snpTrack;
p $phyloPTrack;
p $phastConsTrack;
p $geneTrack;

my $dataAref = $tracks->db->dbRead('chr3', 60830002 );

my $db1 = $tracks->db;
my $db2 = $tracks->db;

say "is $db1 == $db2? " . ($db1 == $db2 ? "YES" : "NO");

my $caddTrack = $tracks->singletonTracks->getTrackGetterByName('cadd');

p $dataAref;

