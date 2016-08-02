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
my $caddTrack = $tracks->singletonTracks->getTrackGetterByName('cadd');

p $refTrack;
p $snpTrack;
p $phyloPTrack;
p $phastConsTrack;
p $geneTrack;

my $db1 = $tracks->db;
my $db2 = $tracks->db;
say "is $db1 == $db2? " . ($db1 == $db2 ? "YES" : "NO");

#TODO:
# chr3  60000 60001 T A 2.444747  19.11
# chr3  60000 60001 T C 2.250965  17.84
# chr3  60000 60001 T G 2.310203  18.23
# chr3  60001 60002 C A 2.103047  16.87
# chr3  60001 60002 C G 1.993745  16.17
# chr3  60001 60002 C T 2.140022  17.12
# chr3  60002 60003 C A 2.167703  17.30
# chr3  60002 60003 C G 2.020147  16.34
# chr3  60002 60003 C T 2.193861  17.47

say "first place with cadd:";

my $dataAref = $tracks->db->dbRead('chr3', 60000 );
p $dataAref;

say "2nd place with cadd:";

$dataAref = $tracks->db->dbRead('chr3', 60001 );
p $dataAref;

say "3rd place with cadd:";

$dataAref = $tracks->db->dbRead('chr3', 60002 );
p $dataAref;

say "place that was once randomly undef'd";
$dataAref = $tracks->db->dbRead('chr3', 60830002 );






#TODO:
# chr3  60830760  60830761  C G -0.095957 1.760
# chr3  60830760  60830761  C T 0.027934  2.859
# chr3  60830761  60830762  C A -0.070796 1.957
# chr3  60830761  60830762  C G -0.180098 1.207
# chr3  60830761  60830762  C T -0.033821 2.273
# chr3  60830762  60830763  R A -0.469198 0.262
# chr3  60830762  60830763  R C -0.500616 0.219
# chr3  60830762  60830763  R G -0.489196 0.234
# chr3  60830762  60830763  R T -0.479178 0.247
# chr3  60830763  60830764  R A -0.103913 1.701
# chr3  60830763  60830764  R C -0.135330 1.482
# chr3  60830763  60830764  R G -0.123910 1.559
# chr3  60830763  60830764  R T -0.113892 1.629
# chr3  60830764  60830765  G A 0.038968  2.970
# chr3  60830764  60830765  G C -0.164394 1.298
# chr3  60830764  60830765  G T -0.039211 2.225
# chr3  60830765  60830766  C A -0.189052 1.157
# chr3  60830765  60830766  C G -0.298354 0.670
# chr3  60830765  60830766  C T -0.152077 1.374
# chr3  60830766  60830767  T A 0.266906  5.367
# chr3  60830766  60830767  T C -0.021283 2.386
# chr3  60830766  60830767  T G 0.102849  3.638
# chr3  60830767  60830768  T A 0.107112  3.684
# chr3  60830767  60830768  T C -0.174172 1.241
# chr3  60830767  60830768  T G -0.064170 2.012

#TODO:

# chr3  60829998  60829999  G A 0.816952  9.568
# chr3  60829998  60829999  G C 0.428257  6.856
# chr3  60829998  60829999  G T 0.624294  8.323
# chr3  60829999  60830000  C A 0.735590  9.058
# chr3  60829999  60830000  C G 0.612158  8.240
# chr3  60829999  60830000  C T 0.745207  9.120
# chr3  60830000  60830001  A C 0.370259  6.351
# chr3  60830000  60830001  A G 0.556016  7.846
# chr3  60830000  60830001  A T 0.436804  6.927
# chr3  60830001  60830002  A C 0.479700  7.274
# chr3  60830001  60830002  A G 0.664363  8.592
# chr3  60830001  60830002  A T 0.560066  7.875
# chr3  60830002  60830003  T A 0.982765  10.56
# chr3  60830002  60830003  T C 0.645025  8.463
# chr3  60830002  60830003  T G 0.821482  9.596
# chr3  60830003  60830004  C A 0.525497  7.623
# chr3  60830003  60830004  C G 0.308163  5.773
# chr3  60830003  60830004  C T 0.359674  6.255
# chr3  60830004  60830005  C A 0.139877  4.037
# chr3  60830004  60830005  C G 0.026349  2.843
# chr3  60830004  60830005  C T 0.175776  4.422
# chr3  60830005  60830006  T A 0.642716  8.447
# chr3  60830005  60830006  T C 0.359057  6.250
# chr3  60830005  60830006  T G 0.461012  7.126

p $dataAref;

# TODO: expect:
# chr3  197962427 197962428 T A 1.255311  12.04
# chr3  197962427 197962428 T C 0.928604  10.25
# chr3  197962427 197962428 T G 1.077718  11.09
# chr3  197962428 197962429 T A 1.208048  11.79
# chr3  197962428 197962429 T C 0.956881  10.41
# chr3  197962428 197962429 T G 1.118649  11.32
# chr3  197962429 197962430 C A 0.874518  9.916
# chr3  197962429 197962430 C G 0.770289  9.279
# chr3  197962429 197962430 C T 0.919103  10.19

say "place without cadd because wierd ref base1:";

$dataAref = $tracks->db->dbRead('chr3', 60830762 );
p $dataAref;

say "place without cadd because wierd ref base2:";
$dataAref = $tracks->db->dbRead('chr3', 60830763 );
p $dataAref;

say "first place after weird ref base2:";
$dataAref = $tracks->db->dbRead('chr3', 60830764 );
p $dataAref;

say "3rd to last with cadd:";
$dataAref = $tracks->db->dbRead('chr3', 197962427 );

p $dataAref;

say "2nd to last with cadd:";
$dataAref = $tracks->db->dbRead('chr3', 197962428 );

p $dataAref;

say "last with cadd:";

$dataAref = $tracks->db->dbRead('chr3', 197962429 );

p $dataAref;
