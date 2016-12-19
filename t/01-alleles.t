use 5.10.0;
use warnings;
use strict;

# TODO: For this test suite, we expect that the gene track properly
# stores codonSequence, codonNumber, codonPosition

package MockAnnotationClass;
use lib './lib';
use Mouse;
extends 'Seq';
use Seq::Tracks;
use DDP;

# For this test, not used
has '+input_file' => (default => 'test.snp');

# output_file_base contains the absolute path to a file base name
# Ex: /dir/child/BaseName ; BaseName is appended with .annotated.tab , .annotated-log.txt, etc
# for the various outputs
has '+output_file_base' => (default => 'test');

has trackIndices => (is => 'ro', isa => 'HashRef', init_arg => undef, writer => '_setTrackIndices');
has trackFeatureIndices => (is => 'ro', isa => 'HashRef', init_arg => undef, writer => '_setTrackFeatureIndices');

sub BUILDARGS {
  my ($self, $data) = @_;

  return $data;
}

sub BUILD {
  my $self = shift;
  $self->{_chrFieldIdx} = 0;
  $self->{_positionFieldIdx} = 1;
  $self->{_referenceFieldIdx} = 2;
  $self->{_alleleFieldIdx} = 3;
  $self->{_typeFieldIdx} = 4;

  my $headers = Seq::Headers->new();

  my %trackIdx = %{ $headers->getParentFeaturesMap() };

  $self->_setTrackIndices(\%trackIdx);

  my %childFeatureIndices;

  for my $trackName (keys %trackIdx ) {
    $childFeatureIndices{$trackName} = $headers->getChildFeaturesMap($trackName);
  }

  $self->_setTrackFeatureIndices(\%childFeatureIndices);
}

1;

package TestRead;
use DDP;
use lib './lib';
use Test::More;
use Seq::DBManager;
use MCE::Loop;
use Utils::SqlWriter::Connection;
use Seq::Headers;
use List::Util qw/first/;

system('touch test.snp');

my $annotator = MockAnnotationClass->new_with_config({ config => './config/hg38.yml'});

system('rm test.snp');

my $sqlClient = Utils::SqlWriter::Connection->new();

my $dbh = $sqlClient->connect('hg38');

my $tracks = Seq::Tracks->new({tracks => $annotator->tracks, gettersOnly => 1});

my $db = Seq::DBManager->new();
# Set the lmdb database to read only, remove locking
# We MUST make sure everything is written to the database by this point
$db->setReadOnly(1);
  
my $geneTrack = $tracks->getTrackGetterByName('refSeq');

my $dataHref;

my $geneTrackIdx = $geneTrack->dbName;
my $nearestTrackIdx = $geneTrack->nearestDbName;

my @allChrs = $geneTrack->allWantedChrs();

my $chr = 'chr22';

plan tests => 4;

my $geneTrackRegionData = $db->dbReadAll( $geneTrack->regionTrackPath($chr) );


#Using the above defined
# $self->{_chrFieldIdx} = 0;
# $self->{_positionFieldIdx} = 1;
# $self->{_referenceFieldIdx} = 2;
# $self->{_alleleFieldIdx} = 3;
# $self->{_typeFieldIdx} = 4;
# 1st and only smaple genotype = 5;
# 1st and only sample genotype confidence = 6

# Seq.pm sets these in the annotate method, based on the input file
# Here we mock that file.
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = (["Sample_1"], [5], [6]);
#This is a bit clunky, check if performance impact of iterating over new range each time that big
$annotator->{_genosIdxRange} = [0];

my $inputAref = [['chr22', 14000001, 'A', 'G', 'SNP', 'G', 1]];

my $dataAref = $db->dbRead('chr22', [14000001  - 1]);

my $outAref = [];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

my @outData = @{$outAref->[0]};

my $trackIndices = $annotator->trackIndices;

my $geneTrackData = $outData[$trackIndices->{refSeq}];

my $headers = Seq::Headers->new();

my @allGeneTrackFeatures = @{ $headers->getParentFeatures($geneTrack->name) };
  
my %geneTrackFeatureMap;
# This includes features added to header, using addFeatureToHeader 
# such as the modified nearest feature names ($nTrackPrefix.$_) and join track names
# and siteType, strand, codonNumber, etc.
for my $i (0 .. $#allGeneTrackFeatures) {
  $geneTrackFeatureMap{ $allGeneTrackFeatures[$i] } = $i;
}

my $sth = $dbh->prepare('SELECT * FROM hg38.refGene WHERE chrom="chr22" AND (txStart <= 14000001 AND txEnd>=14000001) OR (txStart >= 14000001 AND txEnd<=14000001)');

$sth->execute();

#Schema:
#   0 , 1   , 2    , 3      ... 12
# [bin, name, chrom, strand, ...name2,
# 
my @row = $sth->fetchrow_array;

ok(!@row, "UCSC still has 14000001 as intergenic");
ok($geneTrackData->[0][0][0] eq 'intergenic', "We have this as intergenic");


# Check a site with 1 transcript, on the negative strand


$inputAref = [['chr22', 45950000, 'C', 'G', 'SNP', 'G', 1]];

$dataAref = $db->dbRead('chr22', [45950000  - 1]);

$outAref = [];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

$sth = $dbh->prepare("SELECT * FROM hg38.refGene WHERE chrom='chr22' AND (txStart <= 45950000 AND txEnd>=45950000) OR (txStart >= 45950000 AND txEnd<=45950000);");

$sth->execute();

@row = $sth->fetchrow_array;

# TODO: move away from requiring ref name.
my $refTrackIdx = $trackIndices->{ref};
my $txNameIdx = $geneTrackFeatureMap{refseq};
my $geneSymbolIdx = $geneTrackFeatureMap{geneSymbol};
my $refAAidx = $geneTrackFeatureMap{$geneTrack->refAminoAcidKey};
my $altAAidx = $geneTrackFeatureMap{$geneTrack->newAminoAcidKey};
my $refCodonIdx = $geneTrackFeatureMap{$geneTrack->codonSequenceKey};
my $altCodonIdx = $geneTrackFeatureMap{$geneTrack->newCodonKey};
my $strandIdx = $geneTrackFeatureMap{$geneTrack->strandKey};
my $codonPositionIdx = $geneTrackFeatureMap{$geneTrack->codonPositionKey};
my $codonNumberIdx = $geneTrackFeatureMap{$geneTrack->codonNumberKey};

my $exonicAlleleFunctionIdx = $geneTrackFeatureMap{$geneTrack->exonicAlleleFunctionKey};
my $siteTypeIdx = $geneTrackFeatureMap{$geneTrack->siteTypeKey};

ok($row[2] eq 'chr22', 'UCSC still has chr22:45950000 as chr22');
ok($row[2] eq $outData[0][0][0], 'We agree with UCSC that chr22:45950000 is on chromosome chr22');

ok($row[3] eq '-', 'UCSC still has chr22:45950000 as a tx on the negative strand');
ok($row[3] eq $geneTrackData->[$strandIdx][0][0], 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');

ok($row[1] eq 'NM_058238', 'UCSC still has chr22:45950000 as NM_058238');
ok($row[1] eq $geneTrackData->[$txNameIdx][0][0], 'We agree with UCSC that chr22:45950000 transcript is called NM_058238');

ok($row[12] eq 'WNT7B', 'UCSC still has chr22:45950000 as NM_058238');
ok($row[12] eq $geneTrackData->[$geneSymbolIdx][0][0], 'We agree with UCSC that chr22:45950000 transcript geneSymbol is WNT7B');

ok($geneTrackData->[$strandIdx][0][0] eq $row[3], 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'TGC', 'We agree with UCSC that chr22:45950000 codon is TGC');
ok($geneTrackData->[$altCodonIdx][0][0] eq 'TCC', 'We agree with UCSC that chr22:45950000 codon is TCC');

ok($geneTrackData->[$refAAidx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');
ok($geneTrackData->[$altAAidx][0][0] eq 'S', 'The amino acid is changed to S (Serine)');
ok($geneTrackData->[$codonPositionIdx][0][0] == 2, 'We agree with UCSC that chr22:45950000 codon position is 2');
ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950000 is in an exon');

############################## Input data tests ################################
#1 is pos
ok($outData[1][0][0] == 45950000, 'pos is 45950000');

#2 is type
ok($outData[2][0][0] eq 'SNP', 'type is SNP');

#3 is discordant
ok($outData[3][0][0] == 0, 'discordant is 0');

#4 is minorAlleles
ok($outData[4][0][0] eq 'G', 'alt is G');


ok($outData[$refTrackIdx][0][0] eq 'C', 'Reference is C');

#4 is heterozygotes, #5 is homozygotes
ok(!defined $outData[5][0][0], 'We have no hets');
#Samples are stored as either undef, or an array of samples
ok($outData[6][0][0][0] eq 'Sample_1', 'We have one homozygote (Sample_1)');

# Check a site that should be a homozygote, except the confidence is <.95
$inputAref = [['chr22', 45950000, 'C', 'G', 'SNP', 'G', .7]];

$outAref = [];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

#5 is heterozygotes, #6 is homozygotes
ok(!defined $outData[5][0][0], 'We have no hets');

ok(!defined $outData[6][0][0], 'We have no homozygotes, because of low confidence');

# Check a site that has no alleles
$inputAref = [['chr22', 45950000, 'C', 'C', 'SNP', 'C', 1]];

$outAref = [];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(!defined $outData[4][0][0], 'We have no minor alleles');

# Check a site that is discordant
$inputAref = [['chr22', 45950000, 'G', 'G', 'SNP', 'G', 1]];

$outAref = [];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok($outData[3][0][0] == 1, 'Site is discordant');

# Check a site that is heterozygous
$inputAref = [['chr22', 45950000, 'C', 'C,G', 'SNP', 'S', 1]];

$outAref = [];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok($outData[4][0][0] eq 'G', 'We have one minor allele (G)');

ok($outData[5][0][0][0] eq 'Sample_1', 'We have one het (Sample_1)');
ok(!defined $outData[6][0][0], 'We have no homozygotes');

say "\n\nTesting a MULTIALLELIC with 2 alternate alleles (G,A), 1 het, and 1 homozygote for each allele\n";

$inputAref = [['chr22', 45950000, 'C', 'G,C,A', 'MULTIALLELIC', 'G', 1, 'S', 1, 'A', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_1", "Sample_2", "Sample_3"], [5, 7, 9], [6, 8, 10]);

$annotator->{_genosIdxRange} = [0, 1, 2];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[4]} == 2, "We have 2 alleles");
ok($outData[4][0][0] eq 'G', 'First allele is G (preserves allele order of input file');
ok($outData[4][1][0] eq 'A', 'Second allele is A (preserves allele order of input file');
ok(@{$outData[5][0][0]} && $outData[5][0][0][0] eq 'Sample_2', 'We have one het for the first allele');

ok(@{$outData[6][0][0]} == 1 && $outData[6][0][0][0] eq 'Sample_1', 'The first allele has a single homozygote, named Sample_1');
ok(@{$outData[6][1][0]} == 1 && $outData[6][1][0][0] eq 'Sample_3', 'The second allele has a single homozygote, named Sample_3');


############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
    #  #chrom            #pos              #discordant
    if($trackIdx == 0) { #chrom
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array of 1 allele and 1 position");
    } elsif($trackIdx ==1) { #pos
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 2) { #type
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 3) { #discordant
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } else {
      ok(@{$outData[$trackIdx]} == 2 && @{$outData[$trackIdx][0]} == 1 && @{$outData[$trackIdx][1]} == 1,
      "Track $trackName (which has no features) is at least a 2D array, containing two alleles, with one position each");
    }
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 2
    && @{$outData[$trackIdx][$featureIdx][0]} == 1 && @{$outData[$trackIdx][$featureIdx][1]} == 1,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing two alleles, with one position each");
  }
}

$inputAref = [['chr22', 45950000, 'C', 'G,A', 'SNP', 'S', 1, 'A', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

say "\n\nTesting bi-allelic SNP, with one het, and 1 homozygote for the 2nd allele\n";

ok(@{$outData[4]} == 2, "We have 2 alleles, in the case of a biallelic snp");
ok($outData[4][0][0] eq 'G', 'First allele is G (preserves allele order of input file');
ok($outData[4][1][0] eq 'A', 'Second allele is A (preserves allele order of input file');
ok(@{$outData[5][0][0]} && $outData[5][0][0][0] eq 'Sample_4', 'We have one het for the first allele');

ok(!defined $outData[6][0][0], 'The first allele has no homozygotes');
ok(@{$outData[6][1][0]} == 1 && $outData[6][1][0][0] eq 'Sample_5', 'The second allele has a single homozygote, named Sample_5');


############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
    #  #chrom            #pos              #discordant
    if($trackIdx == 0) { #chrom
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array of 1 allele and 1 position");
    } elsif($trackIdx ==1) { #pos
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 2) { #type
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 3) { #discordant
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } else {
      ok(@{$outData[$trackIdx]} == 2 && @{$outData[$trackIdx][0]} == 1 && @{$outData[$trackIdx][1]} == 1,
      "Track $trackName (which has no features) is at least a 2D array, containing two alleles, with one position each");
    }
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 2
    && @{$outData[$trackIdx][$featureIdx][0]} == 1 && @{$outData[$trackIdx][$featureIdx][1]} == 1,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing two alleles, with one position each");
  }
}

say "\n\nTesting a frameshift DEL, with one het, and 1 homozygote\n";

$inputAref = [['chr22', 45950000, 'C', '-2', 'DEL', 'D', 1, 'E', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[0]} == 1 && @{$outData[0][0]} == 1 && $outData[0][0][0] eq 'chr22', "We have one chromosome, chr22");
ok(@{$outData[1]} == 1 && @{$outData[1][0]} == 1 && $outData[1][0][0] == 45950000, "We have only 1 position, 45950000");
ok(@{$outData[2]} == 1 && @{$outData[2][0]} == 1 && $outData[2][0][0] eq 'DEL', "We have only 1 type, DEL");
ok(@{$outData[3]} == 1 && @{$outData[3][0]} == 1 && $outData[3][0][0] == 0, "We have only 1 discordant record, and this row is not discordant");

ok(@{$outData[4]} == 1 && @{$outData[4][0]} == 1 && $outData[4][0][0] == -2, 'We have only 1 allele at 1 position, and it is -2');
ok(@{$outData[5]} == 1 && @{$outData[5][0]} == 1 && $outData[5][0][0][0] eq 'Sample_5', 'We have one het for the only allele');
ok(@{$outData[6]} == 1 && @{$outData[6][0]} == 1 && $outData[6][0][0][0] eq 'Sample_4', 'We have one homozygote for the only allele');

### TODO: how can we query UCSC for the reference genome sequence at a base?
# UCSC has pos 0 as C, pos 1 as A, pos 2 as C. The last base is the 
# last is last base of the upstream (since on negative strand) codon (CTC on the sense == GAG on the antisense == E (Glutamic Acid))
# -2 deletion affects the first position (C) and the next (A) and therefore stays within
# pos 0's (the input row's position) codon (GCA on the sense strand = TGA on the antisense == G (Glycine))
# This position has 3 entries in Genocode v24 in the UCSC browser, for codon position
# 73, 77, 57, 73. It's probably the most common , but for now, accept any one of these

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45949999%2D45950003&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
my @possibleCodonNumbers = (73,77,57);
$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[$refTrackIdx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 reference base is C');
ok($outData[$refTrackIdx][0][1] eq "A", 'We agree with UCSC that chr22:45950001 reference base is A');


ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][1] eq "-", 'We agree with UCSC that chr22:45950001 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'TGC', 'We agree with UCSC that chr22:45950000 codon is TGC');
ok($geneTrackData->[$refCodonIdx][0][1] eq 'TGC', 'We agree with UCSC that chr22:45950001 codon is TGC');

ok(!defined $geneTrackData->[$altCodonIdx][0][0], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][1], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');


# p $geneTrackData->[$refCodonIdx][0][0];
# p $geneTrackData->[$altCodonIdx][0][0];
# p $geneTrackData->[$refAAidx][0][0];
# p $geneTrackData->[$altAAidx][0][0];
ok($geneTrackData->[$refAAidx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');
ok($geneTrackData->[$refAAidx][0][1] eq "C", 'We agree with UCSC that chr22:45950001 codon is C (Cysteine)');

ok(!$geneTrackData->[$altAAidx][0][0], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!$geneTrackData->[$altAAidx][0][1], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');

ok($geneTrackData->[$codonPositionIdx][0][0] == 2, 'We agree with UCSC that chr22:45950000 codon position is 2');
ok($geneTrackData->[$codonPositionIdx][0][1] == 1, 'We agree with UCSC that chr22:45950001 codon position is 1');

ok($geneTrackData->[$codonNumberIdx][0][0] == $geneTrackData->[$codonNumberIdx][0][1], 'Both positions in the deletion are in the same codon');
ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][0] } @possibleCodonNumbers),
  'The refSeq-based codon number we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');


ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950000 is in an exon');
ok($geneTrackData->[$siteTypeIdx][0][1] eq 'exonic', 'We agree with UCSC that chr22:45950001 is in an exon');

# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'indel-frameshift', 'We agree with UCSC that chr22:45950000 is an indel-frameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][1] eq 'indel-frameshift', 'We agree with UCSC that chr22:45950001 is an indel-frameshift');


############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
    #  #chrom            #pos              #discordant
    if($trackIdx == 0) { #chrom
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array of 1 allele and 1 position");
    } elsif($trackIdx ==1) { #pos
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 2) { #type
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 3) { #discordant
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 4) { #alt ; we do not store an allele for each position
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 5) { #heterozygotes ; we do not store a het for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 6) { #homozygotes ; we do not store a homozygote for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } else {
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 2,
      "Track $trackName (which has no features) is at least a 2D array, containing one allele, with two positions");
    }
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 1
    && @{$outData[$trackIdx][$featureIdx][0]} == 2,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing one allele, with two positions");
  }
}

say "\n\nTesting a frameshift DEL (3 base deletion), with one het, and 1 homozygote\n";

$inputAref = [['chr22', 45950000, 'C', '-3', 'DEL', 'D', 1, 'E', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[0]} == 1 && @{$outData[0][0]} == 1 && $outData[0][0][0] eq 'chr22', "We have one chromosome, chr22");
ok(@{$outData[1]} == 1 && @{$outData[1][0]} == 1 && $outData[1][0][0] == 45950000, "We have only 1 position, 45950000");
ok(@{$outData[2]} == 1 && @{$outData[2][0]} == 1 && $outData[2][0][0] eq 'DEL', "We have only 1 type, DEL");
ok(@{$outData[3]} == 1 && @{$outData[3][0]} == 1 && $outData[3][0][0] == 0, "We have only 1 discordant record, and this row is not discordant");

ok(@{$outData[4]} == 1 && @{$outData[4][0]} == 1 && $outData[4][0][0] == -3, 'We have only 1 allele at 1 position, and it is -3');
ok(@{$outData[5]} == 1 && @{$outData[5][0]} == 1 && $outData[5][0][0][0] eq 'Sample_5', 'We have one het for the only allele');
ok(@{$outData[6]} == 1 && @{$outData[6][0]} == 1 && $outData[6][0][0][0] eq 'Sample_4', 'We have one homozygote for the only allele');

### TODO: how can we query UCSC for the reference genome sequence at a base?
# UCSC has pos 0 as C, pos 1 as A, pos 2 as C. The last base is the 
# last is last base of the upstream (since on negative strand) codon (CTC on the sense == GAG on the antisense == E (Glutamic Acid))
# -2 deletion affects the first position (C) and the next (A) and therefore stays within
# pos 0's (the input row's position) codon (GCA on the sense strand = TGA on the antisense == G (Glycine))
# This position has 3 entries in Genocode v24 in the UCSC browser, for codon position
# 73, 77, 57, 73. It's probably the most common , but for now, accept any one of these

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45949999%2D45950003&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
my @possibleCodonNumbersForPositionsOneAndTwo = (73,77,57);
my @possibleCodonNumbersForPositionThree = (72,76,56);

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[$refTrackIdx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 reference base is C');
ok($outData[$refTrackIdx][0][1] eq "A", 'We agree with UCSC that chr22:45950001 reference base is A');
ok($outData[$refTrackIdx][0][2] eq "C", 'We agree with UCSC that chr22:45950002 reference base is C');


ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][1] eq "-", 'We agree with UCSC that chr22:45950001 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][2] eq "-", 'We agree with UCSC that chr22:45950002 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'TGC', 'We agree with UCSC that chr22:45950000 codon is TGC');
ok($geneTrackData->[$refCodonIdx][0][1] eq 'TGC', 'We agree with UCSC that chr22:45950001 codon is TGC');
#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950001%2D45950005&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
# The upstream codon is CTC (sense strand) aka GAG on the antisense strand as in this case
ok($geneTrackData->[$refCodonIdx][0][2] eq 'GAG', 'We agree with UCSC that chr22:45950002 codon is TGC');

ok(!defined $geneTrackData->[$altCodonIdx][0][0], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][1], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][2], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');

ok($geneTrackData->[$refAAidx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');
ok($geneTrackData->[$refAAidx][0][1] eq "C", 'We agree with UCSC that chr22:45950001 codon is C (Cysteine)');
ok($geneTrackData->[$refAAidx][0][2] eq "E", 'We agree with UCSC that chr22:45950001 codon is E (Glutamic Acid)');

ok(!$geneTrackData->[$altAAidx][0][0], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!$geneTrackData->[$altAAidx][0][1], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!$geneTrackData->[$altAAidx][0][2], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');

ok($geneTrackData->[$codonPositionIdx][0][0] == 2, 'We agree with UCSC that chr22:45950000 codon position is 2 (goes backwards relative to sense strand)');
ok($geneTrackData->[$codonPositionIdx][0][1] == 1, 'We agree with UCSC that chr22:45950001 codon position is 1 (goes backwards relative to sense strand)');
ok($geneTrackData->[$codonPositionIdx][0][2] == 3, 'We agree with UCSC that chr22:45950002 codon position is 3 (moved to upstream codon) (goes backwards relative to sense strand)');

ok($geneTrackData->[$codonNumberIdx][0][0] == $geneTrackData->[$codonNumberIdx][0][1], 'Both chr22:45950000 and chr22:45950001 in the deletion are in the same codon');
ok($geneTrackData->[$codonNumberIdx][0][2] < $geneTrackData->[$codonNumberIdx][0][0], 'Both chr22:45950002 is in an upstream codon from chr22:45950000 and chr22:45950001');

ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][0] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');
ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][2] } @possibleCodonNumbersForPositionThree),
  'The refSeq-based codon number we generated is one of the ones listed in UCSC for GENCODE v24 (72, 76, 56)');


ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950000 is in an exon');
ok($geneTrackData->[$siteTypeIdx][0][1] eq 'exonic', 'We agree with UCSC that chr22:45950001 is in an exon');
ok($geneTrackData->[$siteTypeIdx][0][2] eq 'exonic', 'We agree with UCSC that chr22:45950002 is in an exon');

# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950000 is an indel-nonFrameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][1] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950001 is an indel-nonFrameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][2] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950002 is an indel-nonFrameshift');


############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
    #  #chrom            #pos              #discordant
    if($trackIdx == 0) { #chrom
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array of 1 allele and 1 position");
    } elsif($trackIdx ==1) { #pos
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 2) { #type
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 3) { #discordant
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 4) { #alt ; we do not store an allele for each position
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 5) { #heterozygotes ; we do not store a het for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 6) { #homozygotes ; we do not store a homozygote for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } else {
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 3,
      "Track $trackName (which has no features) is at least a 2D array, containing one allele, with two positions");
    }
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 1
    && @{$outData[$trackIdx][$featureIdx][0]} == 3,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing one allele, with three positions");
  }
}

say "\n\nTesting a frameshift DEL (1 base deletion), with one het, and 1 homozygote\n";

$inputAref = [['chr22', 45950000, 'C', '-1', 'DEL', 'D', 1, 'E', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[0]} == 1 && @{$outData[0][0]} == 1 && $outData[0][0][0] eq 'chr22', "We have one chromosome, chr22");
ok(@{$outData[1]} == 1 && @{$outData[1][0]} == 1 && $outData[1][0][0] == 45950000, "We have only 1 position, 45950000");
ok(@{$outData[2]} == 1 && @{$outData[2][0]} == 1 && $outData[2][0][0] eq 'DEL', "We have only 1 type, DEL");
ok(@{$outData[3]} == 1 && @{$outData[3][0]} == 1 && $outData[3][0][0] == 0, "We have only 1 discordant record, and this row is not discordant");

ok(@{$outData[4]} == 1 && @{$outData[4][0]} == 1 && $outData[4][0][0] == -1, 'We have only 1 allele at 1 position, and it is -1');
ok(@{$outData[5]} == 1 && @{$outData[5][0]} == 1 && $outData[5][0][0][0] eq 'Sample_5', 'We have one het for the only allele');
ok(@{$outData[6]} == 1 && @{$outData[6][0]} == 1 && $outData[6][0][0][0] eq 'Sample_4', 'We have one homozygote for the only allele');

### TODO: how can we query UCSC for the reference genome sequence at a base?
# UCSC has pos 0 as C, pos 1 as A, pos 2 as C. The last base is the 
# last is last base of the upstream (since on negative strand) codon (CTC on the sense == GAG on the antisense == E (Glutamic Acid))
# -2 deletion affects the first position (C) and the next (A) and therefore stays within
# pos 0's (the input row's position) codon (GCA on the sense strand = TGA on the antisense == G (Glycine))
# This position has 3 entries in Genocode v24 in the UCSC browser, for codon position
# 73, 77, 57, 73. It's probably the most common , but for now, accept any one of these

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45949999%2D45950003&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
@possibleCodonNumbersForPositionsOneAndTwo = (73,77,57);
@possibleCodonNumbersForPositionThree = (72,76,56);

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[$refTrackIdx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 reference base is C');


ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'TGC', 'We agree with UCSC that chr22:45950000 codon is TGC');

ok(!defined $geneTrackData->[$altCodonIdx][0][0], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');

ok($geneTrackData->[$refAAidx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');

ok(!$geneTrackData->[$altAAidx][0][0], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');

ok($geneTrackData->[$codonPositionIdx][0][0] == 2, 'We agree with UCSC that chr22:45950000 codon position is 2 (goes backwards relative to sense strand)');

ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][0] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');


ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950000 is in an exon');

# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'indel-frameshift', 'We agree with UCSC that chr22:45950000 is an indel-frameshift');

############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
  # The 1 base deletion should look just like a SNP from the architecture of the array
   ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Track $trackName (which has no features) is at least a 2D array, containing one allele, with one positions");
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 1
    && @{$outData[$trackIdx][$featureIdx][0]} == 1,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing one allele, with one position");
  }
}

say "\n\nTesting a frameshift INS (1 base insertion), with one het, and 1 homozygote\n";

$inputAref = [['chr22', 45950000, 'C', '+A', 'INS', 'I', 1, 'H', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[0]} == 1 && @{$outData[0][0]} == 1 && $outData[0][0][0] eq 'chr22', "We have one chromosome, chr22");
ok(@{$outData[1]} == 1 && @{$outData[1][0]} == 1 && $outData[1][0][0] == 45950000, "We have only 1 position, 45950000");
ok(@{$outData[2]} == 1 && @{$outData[2][0]} == 1 && $outData[2][0][0] eq 'INS', "We have only 1 type, INS");
ok(@{$outData[3]} == 1 && @{$outData[3][0]} == 1 && $outData[3][0][0] == 0, "We have only 1 discordant record, and this row is not discordant");

ok(@{$outData[4]} == 1 && @{$outData[4][0]} == 1 && $outData[4][0][0] eq '+A', 'We have only 1 allele at 1 position, and it is +A');
ok(@{$outData[5]} == 1 && @{$outData[5][0]} == 1 && $outData[5][0][0][0] eq 'Sample_5', 'We have one het for the only allele');
ok(@{$outData[6]} == 1 && @{$outData[6][0]} == 1 && $outData[6][0][0][0] eq 'Sample_4', 'We have one homozygote for the only allele');

### TODO: how can we query UCSC for the reference genome sequence at a base?
# UCSC has pos 0 as C, pos 1 as A, pos 2 as C. The last base is the 
# last is last base of the upstream (since on negative strand) codon (CTC on the sense == GAG on the antisense == E (Glutamic Acid))
# -2 deletion affects the first position (C) and the next (A) and therefore stays within
# pos 0's (the input row's position) codon (GCA on the sense strand = TGA on the antisense == G (Glycine))
# This position has 3 entries in Genocode v24 in the UCSC browser, for codon position
# 73, 77, 57, 73. It's probably the most common , but for now, accept any one of these

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45949999%2D45950003&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
@possibleCodonNumbersForPositionsOneAndTwo = (73,77,57);

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[$refTrackIdx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 reference base is C');
ok($outData[$refTrackIdx][0][1] eq "A", 'We agree with UCSC that chr22:45950001 reference base is C');


ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950001 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'TGC', 'We agree with UCSC that chr22:45950000 codon is TGC');
ok($geneTrackData->[$refCodonIdx][0][1] eq 'TGC', 'We agree with UCSC that chr22:45950001 codon is TGC');

ok(!defined $geneTrackData->[$altCodonIdx][0][0], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][1], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');

ok($geneTrackData->[$refAAidx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');
ok($geneTrackData->[$refAAidx][0][1] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');

ok(!$geneTrackData->[$altAAidx][0][0], 'The codon w/ inserted base has no amino acid (we don\'t reconstruct the tx');
ok(!$geneTrackData->[$altAAidx][0][1], 'The codon w/ inserted base has no amino acid (we don\'t reconstruct the tx');

ok($geneTrackData->[$codonPositionIdx][0][0] == 2, 'We agree with UCSC that chr22:45950000 codon position is 2 (goes backwards relative to sense strand)');
ok($geneTrackData->[$codonPositionIdx][0][1] == 1, 'We agree with UCSC that chr22:45950001 codon position is 1 (goes backwards relative to sense strand)');

ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][0] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number for chr22:45950000 we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');
ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][1] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number for chr22:45950001 we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');


ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950000 is in an exon');
ok($geneTrackData->[$siteTypeIdx][0][1] eq 'exonic', 'We agree with UCSC that chr22:45950001 is in an exon');

# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'indel-frameshift', 'We agree with UCSC that chr22:45950000 is an indel-frameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][1] eq 'indel-frameshift', 'We agree with UCSC that chr22:45950001 is an indel-frameshift');

############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
# The 1 base insertion should look just like a 2-base deletion from the architecture of the array
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
    if($trackIdx == 0) { #chrom
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array of 1 allele and 1 position");
    } elsif($trackIdx ==1) { #pos
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 2) { #type
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 3) { #discordant
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 4) { #alt ; we do not store an allele for each position
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 5) { #heterozygotes ; we do not store a het for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 6) { #homozygotes ; we do not store a homozygote for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } else {
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 2,
      "Track $trackName (which has no features) is at least a 2D array, containing one allele, with two positions");
    }
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 1
    && @{$outData[$trackIdx][$featureIdx][0]} == 2,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing one allele, with three positions");
  }
}

say "\n\nTesting a frameshift INS (2 base insertion), with one het, and 1 homozygote\n";

$inputAref = [['chr22', 45950000, 'C', '+AT', 'INS', 'I', 1, 'H', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[0]} == 1 && @{$outData[0][0]} == 1 && $outData[0][0][0] eq 'chr22', "We have one chromosome, chr22");
ok(@{$outData[1]} == 1 && @{$outData[1][0]} == 1 && $outData[1][0][0] == 45950000, "We have only 1 position, 45950000");
ok(@{$outData[2]} == 1 && @{$outData[2][0]} == 1 && $outData[2][0][0] eq 'INS', "We have only 1 type, INS");
ok(@{$outData[3]} == 1 && @{$outData[3][0]} == 1 && $outData[3][0][0] == 0, "We have only 1 discordant record, and this row is not discordant");

ok(@{$outData[4]} == 1 && @{$outData[4][0]} == 1 && $outData[4][0][0] eq '+AT', 'We have only 1 allele at 1 position, and it is +A');
ok(@{$outData[5]} == 1 && @{$outData[5][0]} == 1 && $outData[5][0][0][0] eq 'Sample_5', 'We have one het for the only allele');
ok(@{$outData[6]} == 1 && @{$outData[6][0]} == 1 && $outData[6][0][0][0] eq 'Sample_4', 'We have one homozygote for the only allele');

### TODO: how can we query UCSC for the reference genome sequence at a base?
# UCSC has pos 0 as C, pos 1 as A, pos 2 as C. The last base is the 
# last is last base of the upstream (since on negative strand) codon (CTC on the sense == GAG on the antisense == E (Glutamic Acid))
# -2 deletion affects the first position (C) and the next (A) and therefore stays within
# pos 0's (the input row's position) codon (GCA on the sense strand = TGA on the antisense == G (Glycine))
# This position has 3 entries in Genocode v24 in the UCSC browser, for codon position
# 73, 77, 57, 73. It's probably the most common , but for now, accept any one of these

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45949999%2D45950003&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
@possibleCodonNumbersForPositionsOneAndTwo = (73,77,57);

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[$refTrackIdx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 reference base is C');
ok($outData[$refTrackIdx][0][1] eq "A", 'We agree with UCSC that chr22:45950001 reference base is C');


ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950001 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'TGC', 'We agree with UCSC that chr22:45950000 codon is TGC');
ok($geneTrackData->[$refCodonIdx][0][1] eq 'TGC', 'We agree with UCSC that chr22:45950001 codon is TGC');

ok(!defined $geneTrackData->[$altCodonIdx][0][0], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][1], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');

ok($geneTrackData->[$refAAidx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');
ok($geneTrackData->[$refAAidx][0][1] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');

ok(!$geneTrackData->[$altAAidx][0][0], 'The codon w/ inserted base has no amino acid (we don\'t reconstruct the tx');
ok(!$geneTrackData->[$altAAidx][0][1], 'The codon w/ inserted base has no amino acid (we don\'t reconstruct the tx');

ok($geneTrackData->[$codonPositionIdx][0][0] == 2, 'We agree with UCSC that chr22:45950000 codon position is 2 (goes backwards relative to sense strand)');
ok($geneTrackData->[$codonPositionIdx][0][1] == 1, 'We agree with UCSC that chr22:45950001 codon position is 1 (goes backwards relative to sense strand)');

ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][0] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number for chr22:45950000 we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');
ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][1] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number for chr22:45950001 we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');


ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950000 is in an exon');
ok($geneTrackData->[$siteTypeIdx][0][1] eq 'exonic', 'We agree with UCSC that chr22:45950001 is in an exon');

# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'indel-frameshift', 'We agree with UCSC that chr22:45950000 is an indel-frameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][1] eq 'indel-frameshift', 'We agree with UCSC that chr22:45950001 is an indel-frameshift');

############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
# The 2 base insertion should look just like a 2-base deletion (or a 1 base insertion) from the architecture of the array
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
    if($trackIdx == 0) { #chrom
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array of 1 allele and 1 position");
    } elsif($trackIdx ==1) { #pos
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 2) { #type
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 3) { #discordant
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 4) { #alt ; we do not store an allele for each position
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 5) { #heterozygotes ; we do not store a het for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 6) { #homozygotes ; we do not store a homozygote for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } else {
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 2,
      "Track $trackName (which has no features) is at least a 2D array, containing one allele, with two positions");
    }
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 1
    && @{$outData[$trackIdx][$featureIdx][0]} == 2,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing one allele, with three positions");
  }
}

say "\n\nTesting a nonFrameshift INS (3 base insertion), with one het, and 1 homozygote\n";

$inputAref = [['chr22', 45950000, 'C', '+ATC', 'INS', 'I', 1, 'H', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[0]} == 1 && @{$outData[0][0]} == 1 && $outData[0][0][0] eq 'chr22', "We have one chromosome, chr22");
ok(@{$outData[1]} == 1 && @{$outData[1][0]} == 1 && $outData[1][0][0] == 45950000, "We have only 1 position, 45950000");
ok(@{$outData[2]} == 1 && @{$outData[2][0]} == 1 && $outData[2][0][0] eq 'INS', "We have only 1 type, INS");
ok(@{$outData[3]} == 1 && @{$outData[3][0]} == 1 && $outData[3][0][0] == 0, "We have only 1 discordant record, and this row is not discordant");

ok(@{$outData[4]} == 1 && @{$outData[4][0]} == 1 && $outData[4][0][0] eq '+ATC', 'We have only 1 allele at 1 position, and it is +A');
ok(@{$outData[5]} == 1 && @{$outData[5][0]} == 1 && $outData[5][0][0][0] eq 'Sample_5', 'We have one het for the only allele');
ok(@{$outData[6]} == 1 && @{$outData[6][0]} == 1 && $outData[6][0][0][0] eq 'Sample_4', 'We have one homozygote for the only allele');

### TODO: how can we query UCSC for the reference genome sequence at a base?
# UCSC has pos 0 as C, pos 1 as A, pos 2 as C. The last base is the 
# last is last base of the upstream (since on negative strand) codon (CTC on the sense == GAG on the antisense == E (Glutamic Acid))
# -2 deletion affects the first position (C) and the next (A) and therefore stays within
# pos 0's (the input row's position) codon (GCA on the sense strand = TGA on the antisense == G (Glycine))
# This position has 3 entries in Genocode v24 in the UCSC browser, for codon position
# 73, 77, 57, 73. It's probably the most common , but for now, accept any one of these

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45949999%2D45950003&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
@possibleCodonNumbersForPositionsOneAndTwo = (73,77,57);

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[$refTrackIdx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 reference base is C');
ok($outData[$refTrackIdx][0][1] eq "A", 'We agree with UCSC that chr22:45950001 reference base is C');


ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950000 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950001 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'TGC', 'We agree with UCSC that chr22:45950000 codon is TGC');
ok($geneTrackData->[$refCodonIdx][0][1] eq 'TGC', 'We agree with UCSC that chr22:45950001 codon is TGC');

ok(!defined $geneTrackData->[$altCodonIdx][0][0], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][1], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');

ok($geneTrackData->[$refAAidx][0][0] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');
ok($geneTrackData->[$refAAidx][0][1] eq "C", 'We agree with UCSC that chr22:45950000 codon is C (Cysteine)');

ok(!$geneTrackData->[$altAAidx][0][0], 'The codon w/ inserted base has no amino acid (we don\'t reconstruct the tx');
ok(!$geneTrackData->[$altAAidx][0][1], 'The codon w/ inserted base has no amino acid (we don\'t reconstruct the tx');

ok($geneTrackData->[$codonPositionIdx][0][0] == 2, 'We agree with UCSC that chr22:45950000 codon position is 2 (goes backwards relative to sense strand)');
ok($geneTrackData->[$codonPositionIdx][0][1] == 1, 'We agree with UCSC that chr22:45950001 codon position is 1 (goes backwards relative to sense strand)');

ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][0] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number for chr22:45950000 we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');
ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][1] } @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number for chr22:45950001 we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');


ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950000 is in an exon');
ok($geneTrackData->[$siteTypeIdx][0][1] eq 'exonic', 'We agree with UCSC that chr22:45950001 is in an exon');

# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950000 is an indel-nonFrameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][1] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950001 is an indel-nonFrameshift');

############### Check that in multiple allele cases data is stored as 
### $out[trackIdx][$alleleIdx][$posIdx] = $val or
### $out[trackIdx][$featureIdx][$alleleIdx][$posIdx] = $val for parents with child features
# The 2 base insertion should look just like a 2-base deletion (or a 1 base insertion) from the architecture of the array
for my $trackName ( keys %{ $annotator->trackIndices } ) {
  my $trackIdx = $annotator->trackIndices->{$trackName};

  if(!defined $annotator->trackFeatureIndices->{$trackName}) {
    if($trackIdx == 0) { #chrom
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array of 1 allele and 1 position");
    } elsif($trackIdx ==1) { #pos
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx) is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 2) { #type
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 3) { #discordant
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 4) { #alt ; we do not store an allele for each position
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 5) { #heterozygotes ; we do not store a het for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } elsif($trackIdx == 6) { #homozygotes ; we do not store a homozygote for each position, only for each allele
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 1,
      "Input track $trackName (idx $trackIdx)  is a 2D array, containing two alleles, with one position each");
    } else {
      ok(@{$outData[$trackIdx]} == 1 && @{$outData[$trackIdx][0]} == 2,
      "Track $trackName (which has no features) is at least a 2D array, containing one allele, with two positions");
    }
    
    next;
  }

  for my $featureName ( keys %{ $annotator->trackFeatureIndices->{$trackName} } ) {
    my $featureIdx = $annotator->trackFeatureIndices->{$trackName}{$featureName};
    ok(@{$outData[$trackIdx][$featureIdx]} == 1
    && @{$outData[$trackIdx][$featureIdx][0]} == 2,
    "Track $trackName (idx $trackIdx) feature $featureName (idx $featureIdx) is at least a 2D array, containing one allele, with three positions");
  }
}


say "\n\nTesting a frameshift DEL (3 base deletion), spanning an exon/intron boundry (into spliceAcceptor on negative strand) with one het, and 1 homozygote\n";

# deleted 45950143 - 45950148
#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950143%2D45950148&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
$inputAref = [['chr22', 45950143, 'T', '-6', 'DEL', 'D', 1, 'E', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr22', [45950143 - 1]);

$outAref = [];

$annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

ok(@{$outData[0]} == 1 && @{$outData[0][0]} == 1 && $outData[0][0][0] eq 'chr22', "We have one chromosome, chr22");
ok(@{$outData[1]} == 1 && @{$outData[1][0]} == 1 && $outData[1][0][0] == 45950143, "We have only 1 position, 45950143");
ok(@{$outData[2]} == 1 && @{$outData[2][0]} == 1 && $outData[2][0][0] eq 'DEL', "We have only 1 type, DEL");
ok(@{$outData[3]} == 1 && @{$outData[3][0]} == 1 && $outData[3][0][0] == 0, "We have only 1 discordant record, and this row is not discordant");

ok(@{$outData[4]} == 1 && @{$outData[4][0]} == 1 && $outData[4][0][0] == -6, 'We have only 1 allele at 1 position, and it is -3');
ok(@{$outData[5]} == 1 && @{$outData[5][0]} == 1 && $outData[5][0][0][0] eq 'Sample_5', 'We have one het for the only allele');
ok(@{$outData[6]} == 1 && @{$outData[6][0]} == 1 && $outData[6][0][0][0] eq 'Sample_4', 'We have one homozygote for the only allele');

### TODO: how can we query UCSC for the reference genome sequence at a base?
# UCSC has pos 0 as C, pos 1 as A, pos 2 as C. The last base is the 
# last is last base of the upstream (since on negative strand) codon (CTC on the sense == GAG on the antisense == E (Glutamic Acid))
# -2 deletion affects the first position (C) and the next (A) and therefore stays within
# pos 0's (the input row's position) codon (GCA on the sense strand = TGA on the antisense == G (Glycine))
# This position has 3 entries in Genocode v24 in the UCSC browser, for codon position
# 73, 77, 57, 73. It's probably the most common , but for now, accept any one of these

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45949999%2D45950003&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
my @possibleCodonNumbersForFirstThreePositions = (25,29,9);

# TODO: Check this codon. How is it a 1 base codon? We get it right, but this confuses me.
my @possibleCodonNumbersForFourthPosition = (24,28,8);

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[$refTrackIdx][0][0] eq "T", 'We agree with UCSC that chr22:45950143 reference base is T');
ok($outData[$refTrackIdx][0][1] eq "G", 'We agree with UCSC that chr22:45950144 reference base is G');
ok($outData[$refTrackIdx][0][2] eq "C", 'We agree with UCSC that chr22:45950145 reference base is C');
ok($outData[$refTrackIdx][0][3] eq "T", 'We agree with UCSC that chr22:45950146 reference base is T');
ok($outData[$refTrackIdx][0][4] eq "C", 'We agree with UCSC that chr22:45950147 reference base is C');
ok($outData[$refTrackIdx][0][5] eq "T", 'We agree with UCSC that chr22:45950148 reference base is T');


ok($geneTrackData->[$strandIdx][0][0] eq "-", 'We agree with UCSC that chr22:45950143 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][1] eq "-", 'We agree with UCSC that chr22:45950144 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][2] eq "-", 'We agree with UCSC that chr22:45950145 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][3] eq "-", 'We agree with UCSC that chr22:45950146 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][4] eq "-", 'We agree with UCSC that chr22:45950147 transcript is on the negative strand');
ok($geneTrackData->[$strandIdx][0][5] eq "-", 'We agree with UCSC that chr22:45950148 transcript is on the negative strand');

#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950000%2D45950000&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
ok($geneTrackData->[$refCodonIdx][0][0] eq 'GCA', 'We agree with UCSC that chr22:45950143 codon is GCA');
ok($geneTrackData->[$refCodonIdx][0][1] eq 'GCA', 'We agree with UCSC that chr22:45950144 codon is GCA');
ok($geneTrackData->[$refCodonIdx][0][2] eq 'GCA', 'We agree with UCSC that chr22:45950145 codon is GCA');

#We kind of cheat on this. It's a truncated codon, 1 base, so very hard to judge from the browser what it should be called. It is GGA (glycine) or a codon corresponding to Leucine or Arginine (but refSeq has only the glycine)
ok($geneTrackData->[$refCodonIdx][0][3] eq 'GGA', 'We agree with UCSC that chr22:45950146 codon is GGA');
ok(!defined $geneTrackData->[$refCodonIdx][0][4], 'We agree with UCSC that chr22:45950147 is an intron');
ok(!defined $geneTrackData->[$refCodonIdx][0][5], 'We agree with UCSC that chr22:45950148 is an intron');

ok(!defined $geneTrackData->[$altCodonIdx][0][0], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][1], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][2], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][3], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][4], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altCodonIdx][0][5], 'Codons containing deletions are not reported since we don\'t reconstruct the tx');

#From http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950143%2D45950148&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
#we don't know which one refSeq has
my @possibleGenBankAAForTruncated = ('G', 'L', 'R'); 
ok($geneTrackData->[$refAAidx][0][0] eq "A", 'We agree with UCSC that chr22:45950143 codon is A (Alanine)');
ok($geneTrackData->[$refAAidx][0][1] eq "A", 'We agree with UCSC that chr22:45950144 codon is A (Alanine)');
ok($geneTrackData->[$refAAidx][0][2] eq "A", 'We agree with UCSC that chr22:45950145 codon is A (Alanine)');
ok(!!(first {$_ eq $geneTrackData->[$refAAidx][0][3]} @possibleGenBankAAForTruncated), 'We agree with UCSC that chr22:45950146 amino acid is either G, L, or R (Genbank v.24, we don\'t have UCSC codon for refSeq');
ok(!defined $geneTrackData->[$refAAidx][0][4], 'We agree with UCSC that chr22:45950147 is intronic and therefore has no codon');
ok(!defined $geneTrackData->[$refAAidx][0][5], 'We agree with UCSC that chr22:45950148 is intronic and therefore has no codon');

ok(!defined $geneTrackData->[$altAAidx][0][0], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altAAidx][0][1], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altAAidx][0][2], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altAAidx][0][3], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altAAidx][0][4], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');
ok(!defined $geneTrackData->[$altAAidx][0][5], 'The deleted codon has no amino acid (we don\'t reconstruct the tx');

ok($geneTrackData->[$codonPositionIdx][0][0] == 3, 'We agree with UCSC that chr22:45950143 codon position is 2 (goes backwards relative to sense strand)');
ok($geneTrackData->[$codonPositionIdx][0][1] == 2, 'We agree with UCSC that chr22:45950144 codon position is 1 (goes backwards relative to sense strand)');
ok($geneTrackData->[$codonPositionIdx][0][2] == 1, 'We agree with UCSC that chr22:45950145 codon position is 3 (moved to upstream codon) (goes backwards relative to sense strand)');
# Again, kind of a cheat, it's a truncated codon and UCSC doesn't report the position
ok($geneTrackData->[$codonPositionIdx][0][3] == 3, 'We agree with UCSC that chr22:45950146 codon position is 3 (However, it\'s truncated, so really has only 1 position)');
ok(!defined $geneTrackData->[$codonPositionIdx][0][4], 'We agree with UCSC that chr22:45950147 codon position is 1 (goes backwards relative to sense strand)');
ok(!defined $geneTrackData->[$codonPositionIdx][0][5], 'We agree with UCSC that chr22:45950148 codon position is 3 (moved to upstream codon) (goes backwards relative to sense strand)');

ok($geneTrackData->[$codonNumberIdx][0][0] == $geneTrackData->[$codonNumberIdx][0][1] && $geneTrackData->[$codonNumberIdx][0][0] == $geneTrackData->[$codonNumberIdx][0][2], 'chr22:45950143-45950145 are part of one codon]');
ok($geneTrackData->[$codonNumberIdx][0][3] < $geneTrackData->[$codonNumberIdx][0][0], 'Both chr22:45950143 is in an upstream codon of chr22:45950146');

ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][0] } @possibleCodonNumbersForFirstThreePositions),
  'The refSeq-based codon number we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');
ok(!!(first{ $_ == $geneTrackData->[$codonNumberIdx][0][3] } @possibleCodonNumbersForFourthPosition),
  'The refSeq-based codon number we generated is one of the ones listed in UCSC for GENCODE v24 (72, 76, 56)');

ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr22:45950143 is exonic (in a codon');
ok($geneTrackData->[$siteTypeIdx][0][1] eq 'exonic', 'We agree with UCSC that chr22:45950144 is exonic (in a codon');
ok($geneTrackData->[$siteTypeIdx][0][2] eq 'exonic', 'We agree with UCSC that chr22:45950145 is exonic (in a codon');
ok($geneTrackData->[$siteTypeIdx][0][3] eq 'exonic', 'We agree with UCSC that chr22:45950146 is exonic (in a codon');

# NOTE: These look like they should be splice donor or acceptor, but it's truncated
# We have it as intronic.
# TODO: What should we do in this case??
say "\nNot sure if correct or not (we have intron) \n";

ok($geneTrackData->[$siteTypeIdx][0][4] eq 'spliceAcceptor', 'We agree with UCSC that chr22:45950147 is in an intron. Since it\'s on the neg strand, and the exon is upstream of it on the sense strand, must be spliceAcceptor');
ok($geneTrackData->[$siteTypeIdx][0][5] eq 'spliceAcceptor', 'We agree with UCSC that chr22:45950148 is in an intron. Since it\'s on the neg strand, and the exon is upstream of it on the sense strand, must be spliceAcceptor');

say "OK:";

# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950000 is an indel-nonFrameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][1] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950001 is an indel-nonFrameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][2] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950002 is an indel-nonFrameshift');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][3] eq 'indel-nonFrameshift', 'We agree with UCSC that chr22:45950002 is an indel-nonFrameshift');
ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][4], 'Intronic positions do not get an exonicAlleleFunction');
ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][5], 'Intronic positions do not get an exonicAlleleFunction');



say "\n\nTesting a synonymous stop site SNP  on the negative strand\n";

# deleted 45950143 - 45950148
#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950143%2D45950148&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
$inputAref = [['chr22', 115286071, 'C', 'T', 'SNP', 'C', 1, 'T', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr1', [115286071 - 1]);

$outAref = [];

$annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

# TODO: maybe export the types of names from the gene track package
ok($outData[4][0][0] eq 'T', 'The alt allele is an T');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'synonymous', 'We agree with UCSC that chr1:45950143 C>T is synonymous (stop -> stop)');
ok($geneTrackData->[$refAAidx][0][0] eq '*', 'We agree with UCSC that chr1:45950143 is a stop');
ok($geneTrackData->[$altAAidx][0][0] eq '*', 'We agree with UCSC that chr1:45950143 is a stop');


say "\n\nTesting a stopLoss site SNP on the negative strand gene NGF\n";

# deleted 45950143 - 45950148
#http://genome.ucsc.edu/cgi-bin/hgTracks?db=hg38&lastVirtModeType=default&lastVirtModeExtraState=&virtModeType=default&virtMode=0&nonVirtPosition=&position=chr22%3A45950143%2D45950148&hgsid=572048045_LXaRz5ejmC9V6zso2TTWMLapbn6a
$inputAref = [['chr22', 115286071, 'C', 'A', 'SNP', 'C', 1, 'A', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr1', [115286071 - 1]);

$outAref = [];

$annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

# TODO: maybe export the types of names from the gene track package
ok($outData[4][0][0] eq 'A', 'The alt allele is an A');
ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr1:115286071 is exonic (stop sites are by definition in a codon)');
ok($geneTrackData->[$exonicAlleleFunctionIdx][0][0] eq 'stopLoss', 'We agree with UCSC that chr1:115286071 C>T is synonymous (stop -> stop)');
ok($geneTrackData->[$refAAidx][0][0] eq '*', 'We agree with UCSC that chr1:115286071 is a stop');
ok($geneTrackData->[$altAAidx][0][0] eq 'L', 'We agree with UCSC that chr1:115286071 C>A results in a Leucine(L)');
ok($geneTrackData->[$geneSymbolIdx][0][0] eq 'NGF', 'We agree with UCSC that chr1:115286071 geneSymbol is NGF');

say "\n\nTesting a UTR3 site SNP on the negative strand gene NGF\n";


$inputAref = [['chr22', 115286069, 'C', 'G', 'SNP', 'C', 1, 'G', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr1', [115286069 - 1]);

$outAref = [];

$annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($outData[4][0][0] eq 'G', 'The alt allele is a G');
# TODO: maybe export the types of names from the gene track package
ok($geneTrackData->[$siteTypeIdx][0][0] eq 'UTR3', 'We agree with UCSC that chr1:115286069 is in the UTR3 of NGF');
ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][0], 'UTR3 sites don\'t have exonicAlleleFunction');
ok(!defined $geneTrackData->[$refAAidx][0][0], 'UTR3 sites don\'t have reference amino acids');
ok(!defined $geneTrackData->[$altAAidx][0][0], 'UTR3 sites don\'t have allele amino acids');
ok($geneTrackData->[$geneSymbolIdx][0][0] eq 'NGF', 'We agree with UCSC that chr1:115286069 geneSymbol is NGF');


# Note that the CDS end in refGene is 115286795
my $pos = 115286796;
say "\n\nTesting a UTR5 site SNP on the negative strand gene NGF\n";


$inputAref = [['chr22', $pos, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr1', [$pos - 1]);


$outAref = [];

$annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

$geneTrackRegionData = $db->dbReadAll( $geneTrack->regionTrackPath('chr1') );

# p $geneTrackRegionData->{3755};
# say "and 5";
# p $geneTrackRegionData->{5};

$sth = $dbh->prepare("SELECT * FROM refGene WHERE refGene.name = 'NM_002506'");
$sth->execute();
@row = $sth->fetchrow_array;

my $cdsEnd = $row[7];

ok($outData[4][0][0] eq 'C', 'The alt allele is a G');
# TODO: maybe export the types of names from the gene track package
# cdsEnd is weirdly closed, despite the rest of refGene being half-open....
if($pos >= ($cdsEnd - 1)) {
  ok($geneTrackData->[$siteTypeIdx][0][0] eq 'UTR5', 'We agree with UCSC that chr1:115286796 is in the UTR5 of NGF');
} else {
  ok($geneTrackData->[$siteTypeIdx][0][0] eq 'exonic', 'We agree with UCSC that chr1:115286796 is in the last exon of NGF');
}

ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][0], 'UTR5 sites don\'t have exonicAlleleFunction');
ok(!defined $geneTrackData->[$refAAidx][0][0], 'UTR5 sites don\'t have reference amino acids');
ok(!defined $geneTrackData->[$altAAidx][0][0], 'UTR5 sites don\'t have allele amino acids');
ok($geneTrackData->[$geneSymbolIdx][0][0] eq 'NGF', 'We agree with UCSC that chr1:115286069 geneSymbol is NGF');

# NGF is weird, here is the refGene table:
# mysql> SELECT * FROM refGene WHERE refGene.name2 = 'NGF';
# +------+-----------+-------+--------+-----------+-----------+-----------+-----------+-----------+--------------------------------+--------------------------------+-------+-------+--------------+------------+------------+
# | bin  | name      | chrom | strand | txStart   | txEnd     | cdsStart  | cdsEnd    | exonCount | exonStarts                     | exonEnds                       | score | name2 | cdsStartStat | cdsEndStat | exonFrames |
# +------+-----------+-------+--------+-----------+-----------+-----------+-----------+-----------+--------------------------------+--------------------------------+-------+-------+--------------+------------+------------+
# | 1464 | NM_002506 | chr1  | -      | 115285915 | 115338236 | 115286069 | 115286795 |         3 | 115285915,115293626,115338203, | 115286807,115293750,115338236, |     0 | NGF   | cmpl         | cmpl       | 0,-1,-1,   |
# +------+-----------+-------+--------+-----------+-----------+-----------+-----------+-----------+--------------------------------+--------------------------------+-------+-------+--------------+------------+------------+

# It looks like all of the exonEnds are past the cdsEnd, so ther cannot be a spliceDonor/Acceptor
# my @exonEnds =  split(',', $row[10]);

# my $firstExonHalfClosed = $exonEnds[1];

# p $firstExonHalfClosed;


# say "\n\nTesting a UTR5 site SNP on the negative strand gene NGF\n";


# $inputAref = [['chr22', $firstExonHalfClosed, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
# ($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
#   (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

# $annotator->{_genosIdxRange} = [0, 1];

# $dataAref = $db->dbRead('chr1', [$firstExonHalfClosed - 1]);

# p $dataAref;

# $outAref = [];

# $annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

# @outData = @{$outAref->[0]};

# $geneTrackData = $outData[$trackIndices->{refSeq}];
# p $geneTrackData->[$siteTypeIdx][0][0];
# ok($geneTrackData->[$siteTypeIdx][0][0] eq 'spliceAcceptor', "We agree with UCSC that chr1\:$firstExonHalfClosed is in the last exon of NGF");
# ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][0], 'splice sites don\'t have exonicAlleleFunction');
# ok(!defined $geneTrackData->[$refAAidx][0][0], 'splice sites don\'t have reference amino acids');
# ok(!defined $geneTrackData->[$altAAidx][0][0], 'splice sites don\'t have allele amino acids');
# ok($geneTrackData->[$geneSymbolIdx][0][0] eq 'NGF', 'We agree with UCSC that chr1:115286069 geneSymbol is NGF');

# TODO: Test spliceDonor/spliceAcceptor



