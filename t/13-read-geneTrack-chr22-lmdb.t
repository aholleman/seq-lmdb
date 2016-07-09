use 5.10.0;
use warnings;
use strict;

package MockAnnotationClass;
use lib './lib';
use Mouse;
use MouseX::Types::Path::Tiny qw/AbsDir/;
extends 'Seq::Tracks';

#__PACKAGE__->meta->
1;

package TestRead;
use DDP;

use Test::More;
use List::Util qw/reduce/;
plan tests => 10;

my $tracks = MockAnnotationClass->new_with_config(
  { configfile =>'./config/hg19.lmdb.yml', debug => 1}
);

my $refTrack = $tracks->singletonTracks->getRefTrackGetter();
my $geneTrack = $tracks->singletonTracks->getTrackGetterByName('refSeq');

p $geneTrack;

my $dataHref;
#my $dataHref = $tracks->dbReadAll('chr21');

# say "dataHref is";
# p $dataHref;
say "reading position 161520131";
$dataHref = $tracks->dbRead('chr22', 16152031 - 1);

say "dataHref is";
p $dataHref;
my $ref = $refTrack->get($dataHref);

my $geneData = $geneTrack->get($dataHref, 'chr22', 16152031 - 1, $ref, 'A');

say "geneData is";
p $geneData;

ok($geneData->{'siteType'}->[0] eq 'Intronic', 'Intronic ok at 16152031');

say "reading position 17156061";
$dataHref = $tracks->dbRead('chr22', 17156061 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 17156061 - 1, $ref, 'A');

say "geneData is";
p $geneData;

ok($geneData->{'siteType'}->[0] eq 'NonCodingRNA', 'Exonic ok at 17156061');

say "reading position 17168735";
$dataHref = $tracks->dbRead('chr22', 17168735 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 17168735 - 1, $ref, 'C');
ok($geneData->{'siteType'} eq 'Intergenic', 'Intronic ok at 17168735');

say "geneData is";
p $geneData;

say "reading position 17286712";
$dataHref = $tracks->dbRead('chr22', 17286712 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 17286712 - 1, $ref, 'C');
ok($geneData->{'siteType'}->[0] eq 'Intronic', 'Intronic ok at 17286712');

say "geneData is";
p $geneData;

say "reading position 17444456";
$dataHref = $tracks->dbRead('chr22', 17444456 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 17444456 - 1, $ref, 'C');
ok($geneData->{'siteType'}->[0] eq 'Intronic', 'Intronic ok at 17444456');

say "geneData is";
p $geneData;

say "reading position 17488727";
$dataHref = $tracks->dbRead('chr22', 17488727 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 17488727 - 1, $ref, 'C');

say "geneData is";
p $geneData;

ok($geneData->{'siteType'}->[0] eq 'Intronic', 'intronic ok at 17488727');

say "reading position 17489124";
$dataHref = $tracks->dbRead('chr22', 17489124 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 17489124 - 1, $ref, 'C');
ok($geneData->{'siteType'} eq 'Intergenic', 'Intergenic ok at boundary Intronic site and Intergenic site');
say "geneData is";
p $geneData;

say "reading position 51238065";
$dataHref = $tracks->dbRead('chr22', 51238065 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 51238065 - 1, $ref, 'C');
ok( join(',', @{$geneData->{'siteType'} } ) eq 'NonCodingRNA,NonCodingRNA', 'Exonic non-coding ok @ last exon');

say "geneData is";
p $geneData;

say "reading position 51238066";
$dataHref = $tracks->dbRead('chr22', 51238066 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 51238066 - 1, $ref, 'C');
ok( $geneData->{'siteType'} eq 'Intergenic', 'Intergenic non-coding ok after last exon');
ok( join(",", @{ $geneData->{'nearest.name'} } ) eq 'NR_026981,NR_026982', 'Intergenic non-coding ok after last exon');
say "nearest.name is " . join(",", @{ $geneData->{'nearest.name'} });
say "geneData is";
p $geneData;



say "reading a coding site 39629481";

$dataHref = $tracks->dbRead('chr22', 39629481 - 1);

say "dataHref is";
p $dataHref;

$ref = $refTrack->get($dataHref);

$geneData = $geneTrack->get($dataHref, 'chr22', 39629481 - 1, $ref, 'A');
ok( join(',', @{ $geneData->{'siteType'} } ) eq 'Coding,Coding', 'Coding ok after in PDGFB');
ok( join(',', @{ $geneData->{'geneSymbol'} } ) eq 'PDGFB,PDGFB', 'Gene symbol of all transcripts is PDGFB');

p $geneData;
# $dataHref = $tracks->dbRead('chr21', 48e6);

# say "dataHref is";
# p $dataHref;

# $dataHref = $tracks->dbRead('chr22', 17443433-1);

# say "dataHref is";
# p $dataHref;