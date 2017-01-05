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

say "all gene track features";
p @allGeneTrackFeatures;

say "\nBeginning tests\n";

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

ok(defined(first{$_ == $geneTrackData->[$codonNumberIdx][0][0]} @possibleCodonNumbersForPositionsOneAndTwo),
  'The refSeq-based codon number for chr22:45950000 we generated is one of the ones listed in UCSC for GENCODE v24 (73, 77, 57)');
ok(defined(first{$_ == $geneTrackData->[$codonNumberIdx][0][1]} @possibleCodonNumbersForPositionsOneAndTwo),
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


$inputAref = [['chr1', $pos, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
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
if($pos >= $cdsEnd) {
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

say "\nTesting chr1:115293629 which should be UTR5\n";

$inputAref = [['chr1', 115293629, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr1', [115293629 - 1]);

$outAref = [];

$annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($geneTrackData->[$siteTypeIdx][0][0] eq 'UTR5', "chr1\:115293629 is in the UTR5 NGF");
ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][0], 'UTR5 sites don\'t have exonicAlleleFunction');
ok(!defined $geneTrackData->[$refAAidx][0][0], 'UTR5 sites don\'t have reference amino acids');
ok(!defined $geneTrackData->[$altAAidx][0][0], 'UTR5 sites don\'t have allele amino acids');
ok($geneTrackData->[$geneSymbolIdx][0][0] eq 'NGF', 'We agree with UCSC that chr1:115286069 geneSymbol is NGF');

# TODO: Test spliceDonor/spliceAccptor

say "\nTesting chr1:115338204 which should be UTR5\n";

$inputAref = [['chr1', 115338204, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr1', [115338204 - 1]);

$outAref = [];

$annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($geneTrackData->[$siteTypeIdx][0][0] eq 'UTR5', "chr1\:115338204 is in the UTR5 of NGF");
ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][0], 'UTR5 sites don\'t have exonicAlleleFunction');
ok(!defined $geneTrackData->[$refAAidx][0][0], 'UTR5 sites don\'t have reference amino acids');
ok(!defined $geneTrackData->[$altAAidx][0][0], 'UTR5 sites don\'t have allele amino acids');
ok($geneTrackData->[$geneSymbolIdx][0][0] eq 'NGF', 'We agree with UCSC that chr1:115286069 geneSymbol is NGF');


say "\nTesting chr1:115286806 for splice\n";

$inputAref = [['chr1', 115286806, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
  (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

$annotator->{_genosIdxRange} = [0, 1];

$dataAref = $db->dbRead('chr1', [115286806 - 1]);

$outAref = [];

$annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

@outData = @{$outAref->[0]};

$geneTrackData = $outData[$trackIndices->{refSeq}];

ok($geneTrackData->[$siteTypeIdx][0][0] eq 'spliceAcceptor', "We agree with UCSC that chr1\:115286806 is in the spliceAcceptor of NGF");
ok(!defined $geneTrackData->[$exonicAlleleFunctionIdx][0][0], 'splice sites don\'t have exonicAlleleFunction');
ok(!defined $geneTrackData->[$refAAidx][0][0], 'splice sites don\'t have reference amino acids');
ok(!defined $geneTrackData->[$altAAidx][0][0], 'splice sites don\'t have allele amino acids');
ok($geneTrackData->[$geneSymbolIdx][0][0] eq 'NGF', 'We agree with UCSC that chr1:115286069 geneSymbol is NGF');


# TEST PhastCons && PhyloP
use Seq::Tracks::Score::Build::Round;

my $rounder = Seq::Tracks::Score::Build::Round->new();

my $refTrackGetter = $tracks->getRefTrackGetter();
# say "\nTesting PhastCons 100 way\n";



# $inputAref = [['chr22', 24772303, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
# ($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
#   (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

# $annotator->{_genosIdxRange} = [0, 1];

# $dataAref = $db->dbRead('chr22', [24772303 - 1]);

# p $dataAref;

# $outAref = [];

# $annotator->addTrackData('chr22', $dataAref, $inputAref, $outAref);

# @outData = @{$outAref->[0]};

# my $phastConsData = $outData[$trackIndices->{phastCons}];

# p $phastConsData;

# ok($phastConsData == $rounder->round(.802) + 0, "chr22\:24772303 has a phastCons score of .802 (rounded)");

# say "\nTesting chr1:115286806 for splice\n";

# $inputAref = [['chr22', 115286806, 'T', 'C', 'SNP', 'C', 1, 'G', 1]];
# ($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
#   (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

# $annotator->{_genosIdxRange} = [0, 1];

# $dataAref = $db->dbRead('chr1', [115286806 - 1]);

# p $dataAref;

# $outAref = [];

# $annotator->addTrackData('chr1', $dataAref, $inputAref, $outAref);

# @outData = @{$outAref->[0]};

# $geneTrackData = $outData[$trackIndices->{refSeq}];

# p $geneTrackData;

# p $geneTrackData->[$siteTypeIdx][0][0];
# ok($geneTrackData->[$siteTypeIdx][0][0] eq 'spliceAcceptor', "We agree with UCSC that chr1\:115286806 is in the last exon of NGF");

# Testing PhyloP

say "\nTesting PhyloP 7 way chr22:24772200-24772303\n";

# Comes from
# 24772200  0.146543
# 24772201  0.167
# 24772202  0.167
# 24772203  0.146543
# 24772204  0.126087
# 24772205  0.167
# 24772206  0.146543
# 24772207  0.167
# 24772208  0.146543
# 24772209  0.146543
# 24772210  0.167
# 24772211  0.167
# 24772212  0.146543
# 24772213  0.167
# 24772214  0.167
# 24772215  0.167
# 24772216  0.146543
# 24772217  0.167
# 24772218  0.146543
# 24772219  0.167
# 24772220  0.167
# 24772221  -1.24451
# 24772222  0.146543
# 24772223  0.167
# 24772224  0.167
# 24772225  0.167
# 24772226  0.146543
# 24772227  0.126087
# 24772228  0.146543
# 24772229  0.146543
# 24772230  0.167
# 24772231  0.146543
# 24772232  0.126087
# 24772233  0.167
# 24772234  0.167
# 24772235  0.146543
# 24772236  0.167
# 24772237  0.146543
# 24772238  0.167
# 24772239  0.167
# 24772240  0.146543
# 24772241  0.146543
# 24772242  0.167
# 24772243  0.146543
# 24772244  0.146543
# 24772245  0.167
# 24772246  0.167
# 24772247  0.146543
# 24772248  0.146543
# 24772249  0.167
# 24772250  0.126087
# 24772251  0.146543
# 24772252  0.167
# 24772253  0.167
# 24772254  0.146543
# 24772255  0.146543
# 24772256  0.167
# 24772257  0.146543
# 24772258  0.146543
# 24772259  0.146543
# 24772260  0.146543
# 24772261  0.146543
# 24772262  0.167
# 24772263  0.146543
# 24772264  0.167
# 24772265  0.146543
# 24772266  0.146543
# 24772267  0.146543
# 24772268  0.126087
# 24772269  0.167
# 24772270  0.126087
# 24772271  0.167
# 24772272  0.167
# 24772273  0.146543
# 24772274  -1.24451
# 24772275  0.146543
# 24772276  0.167
# 24772277  0.167
# 24772278  0.146543
# 24772279  0.146543
# 24772280  0.167
# 24772281  0.167
# 24772282  0.167
# 24772283  0.146543
# 24772284  0.126087
# 24772285  0.146543
# 24772286  0.146543
# 24772287  0.167
# 24772288  0.146543
# 24772289  0.167
# 24772290  0.146543
# 24772291  0.146543
# 24772292  0.146543
# 24772293  0.167
# 24772294  0.167
# 24772295  0.146543
# 24772296  0.146543
# 24772297  0.167
# 24772298  0.167
# 24772299  0.146543
# 24772300  0.167
# 24772301  0.167
# 24772302  0.167
# 24772303  0.146543

########## The test #############
# my @phyloP7way = (0.146543,0.167,0.167,0.146543,0.126087,0.167,0.146543,0.167,0.146543,0.146543,0.167,0.167,0.146543,0.167,0.167,0.167,0.146543,0.167,0.146543,0.167,0.167,-1.24451,0.146543,0.167,0.167,0.167,0.146543,0.126087,0.146543,0.146543,0.167,0.146543,0.126087,0.167,0.167,0.146543,0.167,0.146543,0.167,0.167,0.146543,0.146543,0.167,0.146543,0.146543,0.167,0.167,0.146543,0.146543,0.167,0.126087,0.146543,0.167,0.167,0.146543,0.146543,0.167,0.146543,0.146543,0.146543,0.146543,0.146543,0.167,0.146543,0.167,0.146543,0.146543,0.146543,0.126087,0.167,0.126087,0.167,0.167,0.146543,-1.24451,0.146543,0.167,0.167,0.146543,0.146543,0.167,0.167,0.167,0.146543,0.126087,0.146543,0.146543,0.167,0.146543,0.167,0.146543,0.146543,0.146543,0.167,0.167,0.146543,0.146543,0.167,0.167,0.146543,0.167,0.167,0.167,0.146543);

# my @positions = ( 24772200 - 1 .. 24772303 - 1 );
# my @dbData = @positions;
# $db->dbRead('chr22', \@dbData);

# $inputAref = [];

# for my $i ( 0 .. $#positions) {
#   my $refBase = $refTrackGetter->get( $dbData[$i] );
#   push @$inputAref, ['chr22', $positions[$i], $refBase, '-1', 'SNP', $refBase, 1, 'D', 1]
# }

# ($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
#   (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

# $annotator->{_genosIdxRange} = [0, 1];


# $outAref = [];

# $annotator->addTrackData('chr22', \@dbData, $inputAref, $outAref);

# # @outData = @{$outAref->[0]};
# # p @outData;
# # p $outAref;
# my $i = 0;
# for my $data (@$outAref) {
#   my $phyloPdata = $data->[$trackIndices->{phyloP}][0][0];
#   my $ucscRounded = $rounder->round($phyloP7way[$i]);

#   ok($phyloPdata == $ucscRounded, "chr22\:$positions[$i]: our phastCons score: $phyloPdata ; theirs: $ucscRounded ; exact: $phyloP7way[$i]");
#   $i++;
# }

say "\nTesting PhastCons 7 way chr22:24772200-24772303\n";

#PhastCons7way data (as of 12/20/16)
# track type=wiggle_0 name="Cons 7 Verts" description="7 vertebrates conservation by PhastCons"
# output date: 2016-12-20 20:52:13 UTC
# chrom specified: chr22
# position specified: 24772200-24772303
# This data has been compressed with a minor loss in resolution.
# (Worst case: 0.00500781)  The original source data
# (before querying and compression) is available at 
#   http://hgdownload.cse.ucsc.edu/downloads.html
# variableStep chrom=chr22 span=1
# 24772200  0.340118
# 24772201  0.350213
# 24772202  0.360307
# 24772203  0.375449
# 24772204  0.385543
# 24772205  0.390591
# 24772206  0.400685
# 24772207  0.405732
# 24772208  0.415827
# 24772209  0.420874
# 24772210  0.425921
# 24772211  0.430968
# 24772212  0.430968
# 24772213  0.436016
# 24772214  0.436016
# 24772215  0.441063
# 24772216  0.441063
# 24772217  0.441063
# 24772218  0.441063
# 24772219  0.441063
# 24772220  0.436016
# 24772221  0.436016
# 24772222  0.451157
# 24772223  0.466299
# 24772224  0.486488
# 24772225  0.496583
# 24772226  0.511724
# 24772227  0.526866
# 24772228  0.536961
# 24772229  0.547055
# 24772230  0.55715
# 24772231  0.567244
# 24772232  0.577339
# 24772233  0.587433
# 24772234  0.59248
# 24772235  0.602575
# 24772236  0.607622
# 24772237  0.612669
# 24772238  0.617717
# 24772239  0.622764
# 24772240  0.627811
# 24772241  0.632858
# 24772242  0.637906
# 24772243  0.637906
# 24772244  0.642953
# 24772245  0.642953
# 24772246  0.642953
# 24772247  0.648
# 24772248  0.648
# 24772249  0.648
# 24772250  0.648
# 24772251  0.642953
# 24772252  0.642953
# 24772253  0.642953
# 24772254  0.637906
# 24772255  0.637906
# 24772256  0.632858
# 24772257  0.627811
# 24772258  0.627811
# 24772259  0.622764
# 24772260  0.617717
# 24772261  0.607622
# 24772262  0.602575
# 24772263  0.597528
# 24772264  0.587433
# 24772265  0.582386
# 24772266  0.572291
# 24772267  0.562197
# 24772268  0.552102
# 24772269  0.542008
# 24772270  0.531913
# 24772271  0.516772
# 24772272  0.506677
# 24772273  0.491535
# 24772274  0.476394
# 24772275  0.481441
# 24772276  0.486488
# 24772277  0.486488
# 24772278  0.491535
# 24772279  0.491535
# 24772280  0.491535
# 24772281  0.491535
# 24772282  0.491535
# 24772283  0.491535
# 24772284  0.491535
# 24772285  0.486488
# 24772286  0.486488
# 24772287  0.481441
# 24772288  0.476394
# 24772289  0.476394
# 24772290  0.466299
# 24772291  0.461252
# 24772292  0.456205
# 24772293  0.44611
# 24772294  0.441063
# 24772295  0.430968
# 24772296  0.420874
# 24772297  0.41078
# 24772298  0.35526
# 24772299  0.345165
# 24772300  0.330024
# 24772301  0.319929
# 24772302  0.304787
# 24772303  0.289646

############### The test ####################
# my @ucscPhastCons7Way = (0.340118,0.350213,0.360307,0.375449,0.385543,0.390591,0.400685,0.405732,0.415827,0.420874,0.425921,0.430968,0.430968,0.436016,0.436016,0.441063,0.441063,0.441063,0.441063,0.441063,0.436016,0.436016,0.451157,0.466299,0.486488,0.496583,0.511724,0.526866,0.536961,0.547055,0.55715,0.567244,0.577339,0.587433,0.59248,0.602575,0.607622,0.612669,0.617717,0.622764,0.627811,0.632858,0.637906,0.637906,0.642953,0.642953,0.642953,0.648,0.648,0.648,0.648,0.642953,0.642953,0.642953,0.637906,0.637906,0.632858,0.627811,0.627811,0.622764,0.617717,0.607622,0.602575,0.597528,0.587433,0.582386,0.572291,0.562197,0.552102,0.542008,0.531913,0.516772,0.506677,0.491535,0.476394,0.481441,0.486488,0.486488,0.491535,0.491535,0.491535,0.491535,0.491535,0.491535,0.491535,0.486488,0.486488,0.481441,0.476394,0.476394,0.466299,0.461252,0.456205,0.44611,0.441063,0.430968,0.420874,0.41078,0.35526,0.345165,0.330024,0.319929,0.304787,0.289646);

# @positions = ( 24772200 - 1 .. 24772303 - 1 );
# @dbData = @positions;
# $db->dbRead('chr22', \@dbData);

# $inputAref = [];

# for my $i ( 0 .. $#positions) {
#   my $refBase = $refTrackGetter->get( $dbData[$i] );
#   push @$inputAref, ['chr22', $positions[$i], $refBase, '-1', 'SNP', $refBase, 1, 'D', 1]
# }

# ($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
#   (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

# $annotator->{_genosIdxRange} = [0, 1];


# $outAref = [];

# $annotator->addTrackData('chr22', \@dbData, $inputAref, $outAref);

# # @outData = @{$outAref->[0]};
# # p @outData;
# # p $outAref;
# $i = 0;
# for my $data (@$outAref) {
#   my $phastConsData = $data->[$trackIndices->{phastCons}][0][0];
#   my $ucscRounded = $rounder->round($ucscPhastCons7Way[$i]) + 0;

#   # say "ours phastCons: $phastConsData theirs: " . $rounder->round($ucscPhastCons7Way[$i]);
#   ok($phastConsData == $ucscRounded, "chr22\:$positions[$i]: our phastCons score: $phastConsData ; theirs: $ucscRounded ; exact: $ucscPhastCons7Way[$i]");
#   $i++;
# }


say "\nTesting PhastCons 7 way chr19:38000123-38001123\n";

# track type=wiggle_0 name="Cons 7 Verts" description="7 vertebrates conservation by PhastCons"
# output date: 2016-12-20 21:10:31 UTC
# chrom specified: chr19
# position specified: 38000123-38001123
# This data has been compressed with a minor loss in resolution.
# (Worst case: 0.0078125)  The original source data
# (before querying and compression) is available at 
#   http://hgdownload.cse.ucsc.edu/downloads.html
# variableStep chrom=chr19 span=1
# 38000123  0.314961
# 38000124  0.299213
# 38000125  0.275591
# 38000126  0.259843
# 38000127  0.244094
# 38000128  0.220472
# 38000129  0.220472
# 38000130  0.212598
# 38000131  0.212598
# 38000132  0.204724
# 38000133  0.204724
# 38000134  0.19685
# 38000135  0.188976
# 38000136  0.181102
# 38000137  0.188976
# 38000138  0.19685
# 38000139  0.19685
# 38000140  0.204724
# 38000141  0.204724
# 38000142  0.212598
# 38000143  0.212598
# 38000144  0.212598
# 38000145  0.212598
# 38000146  0.212598
# 38000147  0.212598
# 38000148  0.212598
# 38000149  0.212598
# 38000150  0.204724
# 38000151  0.204724
# 38000152  0.19685
# 38000153  0.204724
# 38000154  0.212598
# 38000155  0.228346
# 38000156  0.228346
# 38000157  0.23622
# 38000158  0.244094
# 38000159  0.251969
# 38000160  0.251969
# 38000161  0.259843
# 38000162  0.259843
# 38000163  0.267717
# 38000164  0.267717
# 38000165  0.267717
# 38000166  0.267717
# 38000167  0.267717
# 38000168  0.267717
# 38000169  0.259843
# 38000170  0.259843
# 38000171  0.259843
# 38000172  0.251969
# 38000173  0.244094
# 38000174  0.244094
# 38000175  0.23622
# 38000176  0.228346
# 38000177  0.220472
# 38000178  0.212598
# 38000179  0.19685
# 38000180  0.188976
# 38000181  0.173228
# 38000182  0.165354
# 38000183  0.149606
# 38000184  0.133858
# 38000185  0.11811
# 38000186  0.102362
# 38000187  0.0866142
# 38000188  0.0629921
# 38000189  0.0629921
# 38000190  0.0551181
# 38000191  0.0472441
# 38000192  0.0393701
# 38000193  0.0472441
# 38000194  0.0472441
# 38000195  0.0551181
# 38000196  0.0629921
# 38000197  0.0708661
# 38000198  0.0787402
# 38000199  0.0866142
# 38000200  0.0944882
# 38000201  0.0944882
# 38000202  0.102362
# 38000203  0.102362
# 38000204  0.110236
# 38000205  0.110236
# 38000206  0.110236
# 38000207  0.110236
# 38000208  0.110236
# 38000209  0.110236
# 38000210  0.110236
# 38000211  0.110236
# 38000212  0.110236
# 38000213  0.102362
# 38000214  0.102362
# 38000215  0.0944882
# 38000216  0.0866142
# 38000217  0.0866142
# 38000218  0.0787402
# 38000219  0.0708661
# 38000220  0.0629921
# 38000221  0.0551181
# 38000222  0.0551181
# 38000223  0.0472441
# 38000224  0.0472441
# 38000225  0.0472441
# 38000226  0.0472441
# 38000227  0.0393701
# 38000228  0.0393701
# 38000229  0.0314961
# 38000230  0.0314961
# 38000231  0.023622
# 38000232  0.015748
# 38000233  0.00787402
# 38000234  0.00787402
# 38000235  0.00787402
# 38000236  0.00787402
# 38000237  0.00787402
# 38000238  0.00787402
# 38000239  0.00787402
# 38000240  0.00787402
# 38000241  0.015748
# 38000242  0.015748
# 38000243  0.015748
# 38000244  0.023622
# 38000245  0.0314961
# 38000246  0.0393701
# 38000247  0.0393701
# 38000248  0.0472441
# 38000249  0.0472441
# 38000250  0.0551181
# 38000251  0.0551181
# 38000252  0.0551181
# 38000253  0.0551181
# 38000254  0.0629921
# 38000255  0.0551181
# 38000256  0.0551181
# 38000257  0.0551181
# 38000258  0.0551181
# 38000259  0.0472441
# 38000260  0.0472441
# 38000261  0.0393701
# 38000262  0.0393701
# 38000263  0.0314961
# 38000264  0.023622
# 38000265  0.023622
# 38000266  0.023622
# 38000267  0.023622
# 38000268  0.0314961
# 38000269  0.0314961
# 38000270  0.0393701
# 38000271  0.0393701
# 38000272  0.0472441
# 38000273  0.0472441
# 38000274  0.0472441
# 38000275  0.0472441
# 38000276  0.0472441
# 38000277  0.0472441
# 38000278  0.0472441
# 38000279  0.0472441
# 38000280  0.0393701
# 38000281  0.0393701
# 38000282  0.0314961
# 38000283  0.0314961
# 38000284  0.023622
# 38000285  0.023622
# 38000286  0.015748
# 38000287  0.015748
# 38000288  0.00787402
# 38000289  0.015748
# 38000290  0.015748
# 38000291  0.015748
# 38000292  0.015748
# 38000293  0.015748
# 38000294  0.015748
# 38000295  0.015748
# 38000296  0.023622
# 38000297  0.0393701
# 38000298  0.0551181
# 38000299  0.0708661
# 38000300  0.11811
# 38000301  0.125984
# 38000302  0.141732
# 38000303  0.149606
# 38000304  0.15748
# 38000305  0.165354
# 38000306  0.173228
# 38000307  0.181102
# 38000308  0.188976
# 38000309  0.188976
# 38000310  0.19685
# 38000311  0.19685
# 38000312  0.19685
# 38000313  0.204724
# 38000314  0.204724
# 38000315  0.204724
# 38000316  0.204724
# 38000317  0.19685
# 38000318  0.19685
# 38000319  0.19685
# 38000320  0.188976
# 38000321  0.188976
# 38000322  0.181102
# 38000323  0.173228
# 38000324  0.165354
# 38000325  0.15748
# 38000326  0.149606
# 38000327  0.141732
# 38000328  0.125984
# 38000329  0.11811
# 38000330  0.11811
# 38000331  0.11811
# 38000332  0.11811
# 38000333  0.11811
# 38000334  0.11811
# 38000335  0.11811
# 38000336  0.110236
# 38000337  0.110236
# 38000338  0.110236
# 38000339  0.102362
# 38000340  0.0944882
# 38000341  0.0866142
# 38000342  0.0787402
# 38000343  0.0708661
# 38000344  0.0629921
# 38000345  0.0551181
# 38000346  0.0551181
# 38000347  0.0551181
# 38000348  0.0551181
# 38000349  0.0551181
# 38000350  0.0472441
# 38000351  0.0472441
# 38000352  0.0393701
# 38000353  0.0393701
# 38000354  0.0393701
# 38000355  0.0393701
# 38000356  0.0393701
# 38000357  0.0551181
# 38000358  0.0629921
# 38000359  0.0708661
# 38000360  0.0787402
# 38000361  0.0866142
# 38000362  0.0944882
# 38000363  0.0944882
# 38000364  0.102362
# 38000365  0.110236
# 38000366  0.110236
# 38000367  0.110236
# 38000368  0.11811
# 38000369  0.11811
# 38000370  0.11811
# 38000371  0.11811
# 38000372  0.11811
# 38000373  0.11811
# 38000374  0.110236
# 38000375  0.110236
# 38000376  0.102362
# 38000377  0.102362
# 38000378  0.0944882
# 38000379  0.0944882
# 38000380  0.0866142
# 38000381  0.0787402
# 38000382  0.0708661
# 38000383  0.0708661
# 38000384  0.0708661
# 38000385  0.0708661
# 38000386  0.0708661
# 38000387  0.0708661
# 38000388  0.0629921
# 38000389  0.0629921
# 38000390  0.0629921
# 38000391  0.0551181
# 38000392  0.0472441
# 38000393  0.0472441
# 38000394  0.0472441
# 38000395  0.0472441
# 38000396  0.0472441
# 38000397  0.0472441
# 38000398  0.0472441
# 38000399  0.0472441
# 38000400  0.0472441
# 38000401  0.0551181
# 38000402  0.0629921
# 38000403  0.0708661
# 38000404  0.0708661
# 38000405  0.0787402
# 38000406  0.0787402
# 38000407  0.0787402
# 38000408  0.0866142
# 38000409  0.0866142
# 38000410  0.0866142
# 38000411  0.0866142
# 38000412  0.0866142
# 38000413  0.0787402
# 38000414  0.0787402
# 38000415  0.0787402
# 38000416  0.0708661
# 38000417  0.0708661
# 38000418  0.0708661
# 38000419  0.0787402
# 38000420  0.0787402
# 38000421  0.0787402
# 38000422  0.0866142
# 38000423  0.0866142
# 38000424  0.0866142
# 38000425  0.0866142
# 38000426  0.0944882
# 38000427  0.110236
# 38000428  0.11811
# 38000429  0.125984
# 38000430  0.133858
# 38000431  0.141732
# 38000432  0.149606
# 38000433  0.149606
# 38000434  0.15748
# 38000435  0.15748
# 38000436  0.165354
# 38000437  0.165354
# 38000438  0.165354
# 38000439  0.173228
# 38000440  0.173228
# 38000441  0.173228
# 38000442  0.165354
# 38000443  0.165354
# 38000444  0.165354
# 38000445  0.165354
# 38000446  0.15748
# 38000447  0.15748
# 38000448  0.149606
# 38000449  0.141732
# 38000450  0.133858
# 38000451  0.125984
# 38000452  0.11811
# 38000453  0.110236
# 38000454  0.102362
# 38000455  0.0866142
# 38000456  0.0787402
# 38000457  0.0787402
# 38000458  0.0866142
# 38000459  0.0944882
# 38000460  0.110236
# 38000461  0.114945
# 38000462  0.127717
# 38000463  0.134102
# 38000464  0.140488
# 38000465  0.146874
# 38000466  0.15326
# 38000467  0.159646
# 38000468  0.159646
# 38000469  0.166031
# 38000470  0.166031
# 38000471  0.166031
# 38000472  0.166031
# 38000473  0.166031
# 38000474  0.166031
# 38000475  0.166031
# 38000476  0.166031
# 38000477  0.159646
# 38000478  0.159646
# 38000479  0.15326
# 38000480  0.146874
# 38000481  0.140488
# 38000482  0.134102
# 38000483  0.127717
# 38000484  0.121331
# 38000485  0.108559
# 38000486  0.102173
# 38000487  0.0894016
# 38000488  0.0766299
# 38000489  0.0638583
# 38000490  0.0638583
# 38000491  0.0574724
# 38000492  0.0574724
# 38000493  0.0510866
# 38000494  0.0447008
# 38000495  0.0510866
# 38000496  0.0574724
# 38000497  0.0574724
# 38000498  0.0574724
# 38000499  0.00638583
# 38000500  0
# 38000501  0
# 38000502  0
# 38000503  0.00638583
# 38000504  0.00638583
# 38000505  0.00638583
# 38000506  0.0127717
# 38000507  0.0191575
# 38000508  0.0255433
# 38000509  0.0319291
# 38000510  0.0894016
# 38000511  0.146874
# 38000512  0.197961
# 38000513  0.249047
# 38000514  0.293748
# 38000515  0.344835
# 38000516  0.38315
# 38000517  0.42785
# 38000518  0.466165
# 38000519  0.50448
# 38000520  0.542795
# 38000521  0.568339
# 38000522  0.593882
# 38000523  0.606654
# 38000524  0.619425
# 38000525  0.625811
# 38000526  0.632197
# 38000527  0.638583
# 38000528  0.65774
# 38000529  0.670512
# 38000530  0.676898
# 38000531  0.683283
# 38000532  0.689669
# 38000533  0.689669
# 38000534  0.689669
# 38000535  0.683283
# 38000536  0.676898
# 38000537  0.65774
# 38000538  0.644969
# 38000539  0.625811
# 38000540  0.593882
# 38000541  0.555567
# 38000542  0.50448
# 38000543  0.491709
# 38000544  0.472551
# 38000545  0.440622
# 38000546  0.434236
# 38000547  0.42785
# 38000548  0.408693
# 38000549  0.389535
# 38000550  0.363992
# 38000551  0.332063
# 38000552  0.287362
# 38000553  0.22989
# 38000554  0.159646
# 38000555  0.134102
# 38000556  0.108559
# 38000557  0.0702441
# 38000558  0.0574724
# 38000559  0.0510866
# 38000560  0.0510866
# 38000561  0.038315
# 38000562  0.0319291
# 38000563  0.0255433
# 38000564  0.0255433
# 38000565  0.0255433
# 38000566  0.0319291
# 38000567  0.0319291
# 38000568  0.0255433
# 38000569  0.0255433
# 38000570  0.0319291
# 38000571  0.0319291
# 38000572  0.0319291
# 38000573  0.0319291
# 38000574  0.0255433
# 38000575  0.0191575
# 38000576  0.0191575
# 38000577  0.0127717
# 38000578  0.0127717
# 38000579  0.00638583
# 38000580  0.00638583
# 38000581  0
# 38000582  0
# 38000583  0
# 38000584  0
# 38000585  0
# 38000586  0.00638583
# 38000587  0.00638583
# 38000588  0.00638583
# 38000589  0.00638583
# 38000590  0.00638583
# 38000591  0.00638583
# 38000592  0.0127717
# 38000593  0.0127717
# 38000594  0.0127717
# 38000595  0.0127717
# 38000596  0.0127717
# 38000597  0.0191575
# 38000598  0.0191575
# 38000599  0.0127717
# 38000600  0.0127717
# 38000601  0.00638583
# 38000602  0.00638583
# 38000603  0.0127717
# 38000604  0.0127717
# 38000605  0.0127717
# 38000606  0.0127717
# 38000607  0.0127717
# 38000608  0.00638583
# 38000609  0.00638583
# 38000610  0
# 38000611  0
# 38000612  0
# 38000613  0
# 38000614  0.00638583
# 38000615  0.00638583
# 38000616  0.0127717
# 38000617  0.0255433
# 38000618  0.0319291
# 38000619  0.0510866
# 38000620  0.0574724
# 38000621  0.0638583
# 38000622  0.0638583
# 38000623  0.0574724
# 38000624  0.0574724
# 38000625  0.0638583
# 38000626  0.0830157
# 38000627  0.0894016
# 38000628  0.0894016
# 38000629  0.0894016
# 38000630  0.0766299
# 38000631  0.0638583
# 38000632  0.0319291
# 38000633  0.0255433
# 38000634  0.0191575
# 38000635  0.0191575
# 38000636  0.0127717
# 38000637  0.0127717
# 38000638  0.00638583
# 38000639  0.00638583
# 38000640  0.0127717
# 38000641  0.0319291
# 38000642  0.0447008
# 38000643  0.0638583
# 38000644  0.121331
# 38000645  0.15326
# 38000646  0.172417
# 38000647  0.178803
# 38000648  0.197961
# 38000649  0.210732
# 38000650  0.210732
# 38000651  0.204346
# 38000652  0.197961
# 38000653  0.197961
# 38000654  0.191575
# 38000655  0.191575
# 38000656  0.185189
# 38000657  0.191575
# 38000658  0.191575
# 38000659  0.178803
# 38000660  0.159646
# 38000661  0.127717
# 38000662  0.0766299
# 38000663  0.0510866
# 38000664  0.0447008
# 38000665  0.0319291
# 38000666  0.0255433
# 38000667  0.0191575
# 38000668  0.0127717
# 38000669  0.0127717
# 38000670  0.0127717
# 38000671  0.0191575
# 38000672  0.0319291
# 38000673  0.038315
# 38000674  0.038315
# 38000675  0.038315
# 38000676  0.0319291
# 38000677  0.0255433
# 38000678  0.0191575
# 38000679  0.0127717
# 38000680  0.00638583
# 38000681  0.00638583
# 38000682  0.00638583
# 38000683  0
# 38000684  0
# 38000685  0
# 38000686  0
# 38000687  0
# 38000688  0
# 38000689  0
# 38000690  0
# 38000691  0
# 38000692  0
# 38000693  0.00638583
# 38000694  0.00638583
# 38000695  0.0127717
# 38000696  0.0127717
# 38000697  0.0191575
# 38000698  0.0191575
# 38000699  0.0191575
# 38000700  0.0191575
# 38000701  0.0191575
# 38000702  0.0191575
# 38000703  0.0191575
# 38000704  0.0255433
# 38000705  0.0255433
# 38000706  0.038315
# 38000707  0.0510866
# 38000708  0.0638583
# 38000709  0.0766299
# 38000710  0.0830157
# 38000711  0.0957874
# 38000712  0.102173
# 38000713  0.108559
# 38000714  0.114945
# 38000715  0.121331
# 38000716  0.121331
# 38000717  0.114945
# 38000718  0.114945
# 38000719  0.108559
# 38000720  0.0957874
# 38000721  0.0957874
# 38000722  0.0957874
# 38000723  0.0894016
# 38000724  0.0766299
# 38000725  0.0702441
# 38000726  0.0638583
# 38000727  0.0638583
# 38000728  0.0638583
# 38000729  0.0830157
# 38000730  0.0894016
# 38000731  0.0957874
# 38000732  0.102173
# 38000733  0.102173
# 38000734  0.102173
# 38000735  0.114945
# 38000736  0.121331
# 38000737  0.127717
# 38000738  0.146874
# 38000739  0.166031
# 38000740  0.178803
# 38000741  0.185189
# 38000742  0.197961
# 38000743  0.204346
# 38000744  0.210732
# 38000745  0.217118
# 38000746  0.217118
# 38000747  0.210732
# 38000748  0.210732
# 38000749  0.197961
# 38000750  0.185189
# 38000751  0.166031
# 38000752  0.146874
# 38000753  0.114945
# 38000754  0.108559
# 38000755  0.0957874
# 38000756  0.0830157
# 38000757  0.0766299
# 38000758  0.0766299
# 38000759  0.0638583
# 38000760  0.0510866
# 38000761  0.038315
# 38000762  0.0319291
# 38000763  0.0255433
# 38000764  0.0255433
# 38000765  0.0319291
# 38000766  0.0447008
# 38000767  0.389535
# 38000768  0.491709
# 38000769  0.568339
# 38000770  0.625811
# 38000771  0.676898
# 38000772  0.708827
# 38000773  0.740756
# 38000774  0.759913
# 38000775  0.772685
# 38000776  0.791843
# 38000777  0.798228
# 38000778  0.804614
# 38000779  0.804614
# 38000780  0.811
# 38000781  0.804614
# 38000782  0.804614
# 38000783  0.798228
# 38000784  0.785457
# 38000785  0.772685
# 38000786  0.759913
# 38000787  0.73437
# 38000788  0.708827
# 38000789  0.670512
# 38000790  0.65774
# 38000791  0.638583
# 38000792  0.619425
# 38000793  0.593882
# 38000794  0.561953
# 38000795  0.517252
# 38000796  0.45978
# 38000797  0.440622
# 38000798  0.440622
# 38000799  0.440622
# 38000800  0.42785
# 38000801  0.421465
# 38000802  0.402307
# 38000803  0.402307
# 38000804  0.402307
# 38000805  0.395921
# 38000806  0.38315
# 38000807  0.370378
# 38000808  0.35122
# 38000809  0.35122
# 38000810  0.325677
# 38000811  0.319291
# 38000812  0.30652
# 38000813  0.30652
# 38000814  0.332063
# 38000815  0.344835
# 38000816  0.357606
# 38000817  0.363992
# 38000818  0.370378
# 38000819  0.370378
# 38000820  0.370378
# 38000821  0.363992
# 38000822  0.35122
# 38000823  0.338449
# 38000824  0.319291
# 38000825  0.293748
# 38000826  0.261819
# 38000827  0.217118
# 38000828  0.166031
# 38000829  0.0957874
# 38000830  0.0766299
# 38000831  0.0702441
# 38000832  0.0638583
# 38000833  0.0510866
# 38000834  0.0319291
# 38000835  0.0255433
# 38000836  0.0255433
# 38000837  0.0255433
# 38000838  0.0191575
# 38000839  0.0127717
# 38000840  0.0127717
# 38000841  0.0127717
# 38000842  0.0191575
# 38000843  0.0255433
# 38000844  0.0447008
# 38000845  0.0574724
# 38000846  0.0766299
# 38000847  0.0830157
# 38000848  0.0957874
# 38000849  0.102173
# 38000850  0.102173
# 38000851  0.102173
# 38000852  0.114945
# 38000853  0.121331
# 38000854  0.127717
# 38000855  0.127717
# 38000856  0.127717
# 38000857  0.140488
# 38000858  0.146874
# 38000859  0.15326
# 38000860  0.15326
# 38000861  0.15326
# 38000862  0.146874
# 38000863  0.140488
# 38000864  0.127717
# 38000865  0.108559
# 38000866  0.102173
# 38000867  0.108559
# 38000868  0.114945
# 38000869  0.114945
# 38000870  0.114945
# 38000871  0.108559
# 38000872  0.102173
# 38000873  0.0957874
# 38000874  0.0766299
# 38000875  0.0638583
# 38000876  0.038315
# 38000877  0.00638583
# 38000878  0.00638583
# 38000879  0
# 38000880  0.00638583
# 38000881  0.00638583
# 38000882  0
# 38000883  0
# 38000884  0
# 38000885  0
# 38000886  0.0127717
# 38000887  0.0191575
# 38000888  0.0255433
# 38000889  0.0255433
# 38000890  0.0319291
# 38000891  0.0319291
# 38000892  0.0319291
# 38000893  0.0319291
# 38000894  0.0319291
# 38000895  0.0319291
# 38000896  0.0319291
# 38000897  0.0255433
# 38000898  0.0191575
# 38000899  0.0127717
# 38000900  0.0127717
# 38000901  0.00638583
# 38000902  0.00638583
# 38000903  0.00638583
# 38000904  0.00638583
# 38000905  0.00638583
# 38000906  0.0127717
# 38000907  0.0127717
# 38000908  0.0127717
# 38000909  0.0127717
# 38000910  0.0127717
# 38000911  0.0127717
# 38000912  0.00638583
# 38000913  0.00638583
# 38000914  0
# 38000915  0
# 38000916  0
# 38000917  0
# 38000918  0
# 38000919  0
# 38000920  0
# 38000921  0
# 38000922  0
# 38000923  0
# 38000924  0
# 38000925  0
# 38000926  0
# 38000927  0.00638583
# 38000928  0.00638583
# 38000929  0
# 38000930  0
# 38000931  0
# 38000932  0
# 38000933  0
# 38000934  0
# 38000935  0
# 38000936  0
# 38000937  0
# 38000938  0
# 38000939  0
# 38000940  0
# 38000941  0
# 38000942  0
# 38000943  0
# 38000944  0
# 38000945  0
# 38000946  0
# 38000947  0
# 38000948  0
# 38000949  0
# 38000950  0
# 38000951  0
# 38000952  0
# 38000953  0
# 38000954  0
# 38000955  0
# 38000956  0
# 38000957  0
# 38000958  0
# 38000959  0
# 38000960  0
# 38000961  0
# 38000962  0
# 38000963  0
# 38000964  0
# 38000965  0.00638583
# 38000966  0.00638583
# 38000967  0.00638583
# 38000968  0.0127717
# 38000969  0.0127717
# 38000970  0.0127717
# 38000971  0.00638583
# 38000972  0.00638583
# 38000973  0.00638583
# 38000974  0.00638583
# 38000975  0.00638583
# 38000976  0.00638583
# 38000977  0.00638583
# 38000978  0.00638583
# 38000979  0.00638583
# 38000980  0.00638583
# 38000981  0.00638583
# 38000982  0.0127717
# 38000983  0.0127717
# 38000984  0.0127717
# 38000985  0.0127717
# 38000986  0.0127717
# 38000987  0.0127717
# 38000988  0.00638583
# 38000989  0.00638583
# 38000990  0.00638583
# 38000991  0
# 38000992  0
# 38000993  0
# 38000994  0
# 38000995  0
# 38000996  0
# 38000997  0
# 38000998  0
# 38000999  0
# 38001000  0
# 38001001  0
# 38001002  0
# 38001003  0
# 38001004  0
# 38001005  0
# 38001006  0
# 38001007  0
# 38001008  0
# 38001009  0
# 38001010  0.00638583
# 38001011  0.0127717
# 38001012  0.0127717
# 38001013  0.0191575
# 38001014  0.0191575
# 38001015  0.0191575
# 38001016  0.0255433
# 38001017  0.0255433
# 38001018  0.0255433
# 38001019  0.0319291
# 38001020  0.0319291
# 38001021  0.0319291
# 38001022  0.0319291
# 38001023  0.0319291
# 38001024  0.0255433
# 38001025  0.0255433
# 38001026  0.0255433
# 38001027  0.0255433
# 38001028  0.0191575
# 38001029  0.0255433
# 38001030  0.0255433
# 38001031  0.0255433
# 38001032  0.0319291
# 38001033  0.0319291
# 38001034  0.0319291
# 38001035  0.0319291
# 38001036  0.0319291
# 38001037  0.0319291
# 38001038  0.0319291
# 38001039  0.0255433
# 38001040  0.0319291
# 38001041  0.038315
# 38001042  0.0447008
# 38001043  0.0447008
# 38001044  0.0510866
# 38001045  0.0574724
# 38001046  0.0574724
# 38001047  0.0638583
# 38001048  0.0638583
# 38001049  0.0638583
# 38001050  0.0702441
# 38001051  0.0638583
# 38001052  0.0638583
# 38001053  0.0702441
# 38001054  0.0766299
# 38001055  0.0894016
# 38001056  0.0957874
# 38001057  0.102173
# 38001058  0.108559
# 38001059  0.114945
# 38001060  0.114945
# 38001061  0.121331
# 38001062  0.127717
# 38001063  0.127717
# 38001064  0.134102
# 38001065  0.140488
# 38001066  0.140488
# 38001067  0.146874
# 38001068  0.146874
# 38001069  0.15326
# 38001070  0.15326
# 38001071  0.159646
# 38001072  0.159646
# 38001073  0.159646
# 38001074  0.159646
# 38001075  0.166031
# 38001076  0.166031
# 38001077  0.166031
# 38001078  0.166031
# 38001079  0.166031
# 38001080  0.166031
# 38001081  0.166031
# 38001082  0.166031
# 38001083  0.166031
# 38001084  0.159646
# 38001085  0.159646
# 38001086  0.159646
# 38001087  0.159646
# 38001088  0.15326
# 38001089  0.146874
# 38001090  0.146874
# 38001091  0.140488
# 38001092  0.127717
# 38001093  0.121331
# 38001094  0.114945
# 38001095  0.102173
# 38001096  0.0957874
# 38001097  0.0830157
# 38001098  0.0702441
# 38001099  0.0574724
# 38001100  0.0447008
# 38001101  0.0319291
# 38001102  0.0255433
# 38001103  0.0191575
# 38001104  0.0127717
# 38001105  0.0191575
# 38001106  0.0191575
# 38001107  0.0191575
# 38001108  0.0127717
# 38001109  0.0127717
# 38001110  0.00638583
# 38001111  0
# 38001112  0.00638583
# 38001113  0.00638583
# 38001114  0.0127717
# 38001115  0.0255433
# 38001116  0.0255433
# 38001117  0.0319291
# 38001118  0.0319291
# 38001119  0.0319291
# 38001120  0.0319291
# 38001121  0.0510866
# 38001122  0.0574724
# 38001123  0.0702441


######################### The test ##########################
# @ucscPhastCons7Way = (0.314961,0.299213,0.275591,0.259843,0.244094,0.220472,0.220472,0.212598,0.212598,0.204724,0.204724,0.19685,0.188976,0.181102,0.188976,0.19685,0.19685,0.204724,0.204724,0.212598,0.212598,0.212598,0.212598,0.212598,0.212598,0.212598,0.212598,0.204724,0.204724,0.19685,0.204724,0.212598,0.228346,0.228346,0.23622,0.244094,0.251969,0.251969,0.259843,0.259843,0.267717,0.267717,0.267717,0.267717,0.267717,0.267717,0.259843,0.259843,0.259843,0.251969,0.244094,0.244094,0.23622,0.228346,0.220472,0.212598,0.19685,0.188976,0.173228,0.165354,0.149606,0.133858,0.11811,0.102362,0.0866142,0.0629921,0.0629921,0.0551181,0.0472441,0.0393701,0.0472441,0.0472441,0.0551181,0.0629921,0.0708661,0.0787402,0.0866142,0.0944882,0.0944882,0.102362,0.102362,0.110236,0.110236,0.110236,0.110236,0.110236,0.110236,0.110236,0.110236,0.110236,0.102362,0.102362,0.0944882,0.0866142,0.0866142,0.0787402,0.0708661,0.0629921,0.0551181,0.0551181,0.0472441,0.0472441,0.0472441,0.0472441,0.0393701,0.0393701,0.0314961,0.0314961,0.023622,0.015748,0.00787402,0.00787402,0.00787402,0.00787402,0.00787402,0.00787402,0.00787402,0.00787402,0.015748,0.015748,0.015748,0.023622,0.0314961,0.0393701,0.0393701,0.0472441,0.0472441,0.0551181,0.0551181,0.0551181,0.0551181,0.0629921,0.0551181,0.0551181,0.0551181,0.0551181,0.0472441,0.0472441,0.0393701,0.0393701,0.0314961,0.023622,0.023622,0.023622,0.023622,0.0314961,0.0314961,0.0393701,0.0393701,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0393701,0.0393701,0.0314961,0.0314961,0.023622,0.023622,0.015748,0.015748,0.00787402,0.015748,0.015748,0.015748,0.015748,0.015748,0.015748,0.015748,0.023622,0.0393701,0.0551181,0.0708661,0.11811,0.125984,0.141732,0.149606,0.15748,0.165354,0.173228,0.181102,0.188976,0.188976,0.19685,0.19685,0.19685,0.204724,0.204724,0.204724,0.204724,0.19685,0.19685,0.19685,0.188976,0.188976,0.181102,0.173228,0.165354,0.15748,0.149606,0.141732,0.125984,0.11811,0.11811,0.11811,0.11811,0.11811,0.11811,0.11811,0.110236,0.110236,0.110236,0.102362,0.0944882,0.0866142,0.0787402,0.0708661,0.0629921,0.0551181,0.0551181,0.0551181,0.0551181,0.0551181,0.0472441,0.0472441,0.0393701,0.0393701,0.0393701,0.0393701,0.0393701,0.0551181,0.0629921,0.0708661,0.0787402,0.0866142,0.0944882,0.0944882,0.102362,0.110236,0.110236,0.110236,0.11811,0.11811,0.11811,0.11811,0.11811,0.11811,0.110236,0.110236,0.102362,0.102362,0.0944882,0.0944882,0.0866142,0.0787402,0.0708661,0.0708661,0.0708661,0.0708661,0.0708661,0.0708661,0.0629921,0.0629921,0.0629921,0.0551181,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0472441,0.0551181,0.0629921,0.0708661,0.0708661,0.0787402,0.0787402,0.0787402,0.0866142,0.0866142,0.0866142,0.0866142,0.0866142,0.0787402,0.0787402,0.0787402,0.0708661,0.0708661,0.0708661,0.0787402,0.0787402,0.0787402,0.0866142,0.0866142,0.0866142,0.0866142,0.0944882,0.110236,0.11811,0.125984,0.133858,0.141732,0.149606,0.149606,0.15748,0.15748,0.165354,0.165354,0.165354,0.173228,0.173228,0.173228,0.165354,0.165354,0.165354,0.165354,0.15748,0.15748,0.149606,0.141732,0.133858,0.125984,0.11811,0.110236,0.102362,0.0866142,0.0787402,0.0787402,0.0866142,0.0944882,0.110236,0.114945,0.127717,0.134102,0.140488,0.146874,0.15326,0.159646,0.159646,0.166031,0.166031,0.166031,0.166031,0.166031,0.166031,0.166031,0.166031,0.159646,0.159646,0.15326,0.146874,0.140488,0.134102,0.127717,0.121331,0.108559,0.102173,0.0894016,0.0766299,0.0638583,0.0638583,0.0574724,0.0574724,0.0510866,0.0447008,0.0510866,0.0574724,0.0574724,0.0574724,0.00638583,0,0,0,0.00638583,0.00638583,0.00638583,0.0127717,0.0191575,0.0255433,0.0319291,0.0894016,0.146874,0.197961,0.249047,0.293748,0.344835,0.38315,0.42785,0.466165,0.50448,0.542795,0.568339,0.593882,0.606654,0.619425,0.625811,0.632197,0.638583,0.65774,0.670512,0.676898,0.683283,0.689669,0.689669,0.689669,0.683283,0.676898,0.65774,0.644969,0.625811,0.593882,0.555567,0.50448,0.491709,0.472551,0.440622,0.434236,0.42785,0.408693,0.389535,0.363992,0.332063,0.287362,0.22989,0.159646,0.134102,0.108559,0.0702441,0.0574724,0.0510866,0.0510866,0.038315,0.0319291,0.0255433,0.0255433,0.0255433,0.0319291,0.0319291,0.0255433,0.0255433,0.0319291,0.0319291,0.0319291,0.0319291,0.0255433,0.0191575,0.0191575,0.0127717,0.0127717,0.00638583,0.00638583,0,0,0,0,0,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.0127717,0.0127717,0.0127717,0.0127717,0.0127717,0.0191575,0.0191575,0.0127717,0.0127717,0.00638583,0.00638583,0.0127717,0.0127717,0.0127717,0.0127717,0.0127717,0.00638583,0.00638583,0,0,0,0,0.00638583,0.00638583,0.0127717,0.0255433,0.0319291,0.0510866,0.0574724,0.0638583,0.0638583,0.0574724,0.0574724,0.0638583,0.0830157,0.0894016,0.0894016,0.0894016,0.0766299,0.0638583,0.0319291,0.0255433,0.0191575,0.0191575,0.0127717,0.0127717,0.00638583,0.00638583,0.0127717,0.0319291,0.0447008,0.0638583,0.121331,0.15326,0.172417,0.178803,0.197961,0.210732,0.210732,0.204346,0.197961,0.197961,0.191575,0.191575,0.185189,0.191575,0.191575,0.178803,0.159646,0.127717,0.0766299,0.0510866,0.0447008,0.0319291,0.0255433,0.0191575,0.0127717,0.0127717,0.0127717,0.0191575,0.0319291,0.038315,0.038315,0.038315,0.0319291,0.0255433,0.0191575,0.0127717,0.00638583,0.00638583,0.00638583,0,0,0,0,0,0,0,0,0,0,0.00638583,0.00638583,0.0127717,0.0127717,0.0191575,0.0191575,0.0191575,0.0191575,0.0191575,0.0191575,0.0191575,0.0255433,0.0255433,0.038315,0.0510866,0.0638583,0.0766299,0.0830157,0.0957874,0.102173,0.108559,0.114945,0.121331,0.121331,0.114945,0.114945,0.108559,0.0957874,0.0957874,0.0957874,0.0894016,0.0766299,0.0702441,0.0638583,0.0638583,0.0638583,0.0830157,0.0894016,0.0957874,0.102173,0.102173,0.102173,0.114945,0.121331,0.127717,0.146874,0.166031,0.178803,0.185189,0.197961,0.204346,0.210732,0.217118,0.217118,0.210732,0.210732,0.197961,0.185189,0.166031,0.146874,0.114945,0.108559,0.0957874,0.0830157,0.0766299,0.0766299,0.0638583,0.0510866,0.038315,0.0319291,0.0255433,0.0255433,0.0319291,0.0447008,0.389535,0.491709,0.568339,0.625811,0.676898,0.708827,0.740756,0.759913,0.772685,0.791843,0.798228,0.804614,0.804614,0.811,0.804614,0.804614,0.798228,0.785457,0.772685,0.759913,0.73437,0.708827,0.670512,0.65774,0.638583,0.619425,0.593882,0.561953,0.517252,0.45978,0.440622,0.440622,0.440622,0.42785,0.421465,0.402307,0.402307,0.402307,0.395921,0.38315,0.370378,0.35122,0.35122,0.325677,0.319291,0.30652,0.30652,0.332063,0.344835,0.357606,0.363992,0.370378,0.370378,0.370378,0.363992,0.35122,0.338449,0.319291,0.293748,0.261819,0.217118,0.166031,0.0957874,0.0766299,0.0702441,0.0638583,0.0510866,0.0319291,0.0255433,0.0255433,0.0255433,0.0191575,0.0127717,0.0127717,0.0127717,0.0191575,0.0255433,0.0447008,0.0574724,0.0766299,0.0830157,0.0957874,0.102173,0.102173,0.102173,0.114945,0.121331,0.127717,0.127717,0.127717,0.140488,0.146874,0.15326,0.15326,0.15326,0.146874,0.140488,0.127717,0.108559,0.102173,0.108559,0.114945,0.114945,0.114945,0.108559,0.102173,0.0957874,0.0766299,0.0638583,0.038315,0.00638583,0.00638583,0,0.00638583,0.00638583,0,0,0,0,0.0127717,0.0191575,0.0255433,0.0255433,0.0319291,0.0319291,0.0319291,0.0319291,0.0319291,0.0319291,0.0319291,0.0255433,0.0191575,0.0127717,0.0127717,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.0127717,0.0127717,0.0127717,0.0127717,0.0127717,0.0127717,0.00638583,0.00638583,0,0,0,0,0,0,0,0,0,0,0,0,0,0.00638583,0.00638583,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.00638583,0.00638583,0.00638583,0.0127717,0.0127717,0.0127717,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.00638583,0.0127717,0.0127717,0.0127717,0.0127717,0.0127717,0.0127717,0.00638583,0.00638583,0.00638583,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.00638583,0.0127717,0.0127717,0.0191575,0.0191575,0.0191575,0.0255433,0.0255433,0.0255433,0.0319291,0.0319291,0.0319291,0.0319291,0.0319291,0.0255433,0.0255433,0.0255433,0.0255433,0.0191575,0.0255433,0.0255433,0.0255433,0.0319291,0.0319291,0.0319291,0.0319291,0.0319291,0.0319291,0.0319291,0.0255433,0.0319291,0.038315,0.0447008,0.0447008,0.0510866,0.0574724,0.0574724,0.0638583,0.0638583,0.0638583,0.0702441,0.0638583,0.0638583,0.0702441,0.0766299,0.0894016,0.0957874,0.102173,0.108559,0.114945,0.114945,0.121331,0.127717,0.127717,0.134102,0.140488,0.140488,0.146874,0.146874,0.15326,0.15326,0.159646,0.159646,0.159646,0.159646,0.166031,0.166031,0.166031,0.166031,0.166031,0.166031,0.166031,0.166031,0.166031,0.159646,0.159646,0.159646,0.159646,0.15326,0.146874,0.146874,0.140488,0.127717,0.121331,0.114945,0.102173,0.0957874,0.0830157,0.0702441,0.0574724,0.0447008,0.0319291,0.0255433,0.0191575,0.0127717,0.0191575,0.0191575,0.0191575,0.0127717,0.0127717,0.00638583,0,0.00638583,0.00638583,0.0127717,0.0255433,0.0255433,0.0319291,0.0319291,0.0319291,0.0319291,0.0510866,0.0574724,0.0702441);

# @positions = ( 38000123 - 1 .. 38001123 - 1 );
# @dbData = @positions;
# $db->dbRead('chr19', \@dbData);

# $inputAref = [];

# for my $i ( 0 .. $#positions) {
#   my $refBase = $refTrackGetter->get( $dbData[$i] );
#   push @$inputAref, ['chr19', $positions[$i], $refBase, '-1', 'SNP', $refBase, 1, 'D', 1]
# }

# ($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
#   (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

# $annotator->{_genosIdxRange} = [0, 1];


# $outAref = [];

# $annotator->addTrackData('chr22', \@dbData, $inputAref, $outAref);

# # @outData = @{$outAref->[0]};
# # p @outData;
# # p $outAref;
# $i = 0;
# for my $data (@$outAref) {
#   my $phastConsData = $data->[$trackIndices->{phastCons}][0][0];
#   my $ucscRounded = $rounder->round($ucscPhastCons7Way[$i]) + 0;

#   # say "ours phastCons: $phastConsData theirs: " . $rounder->round($ucscPhastCons7Way[$i]);
#   ok($phastConsData == $ucscRounded, "chr19\:$positions[$i]: our phastCons score: $phastConsData ; theirs: $ucscRounded ; exact: $ucscPhastCons7Way[$i]");
#   $i++;
# }


# say "\nTesting PhyloP 7 way chr19:38000123-38001123\n";

# track type=wiggle_0 name="Cons 7 Verts" description="7 vertebrates Basewise Conservation by PhyloP"
# output date: 2016-12-20 21:18:56 UTC
# chrom specified: chr19
# position specified: 38000123-38001123
# This data has been compressed with a minor loss in resolution.
# (Worst case: 0.033)  The original source data
# (before querying and compression) is available at 
#   http://hgdownload.cse.ucsc.edu/downloads.html
# variableStep chrom=chr19 span=1
# 38000123  0.138535
# 38000124  0.138535
# 38000125  0.138535
# 38000126  0.138535
# 38000127  0.138535
# 38000128  -1.24666
# 38000129  0.138535
# 38000130  0.138535
# 38000131  0.138535
# 38000132  0.138535
# 38000133  0.138535
# 38000134  0.138535
# 38000135  0.138535
# 38000136  -1.24666
# 38000137  0.138535
# 38000138  0.138535
# 38000139  0.138535
# 38000140  0.138535
# 38000141  0.138535
# 38000142  0.138535
# 38000143  0.138535
# 38000144  0.138535
# 38000145  0.138535
# 38000146  0.138535
# 38000147  0.138535
# 38000148  0.138535
# 38000149  0.138535
# 38000150  0.138535
# 38000151  0.138535
# 38000152  -1.59296
# 38000153  0.138535
# 38000154  0.138535
# 38000155  0.138535
# 38000156  0.138535
# 38000157  0.138535
# 38000158  0.138535
# 38000159  0.138535
# 38000160  0.138535
# 38000161  0.138535
# 38000162  0.138535
# 38000163  0.138535
# 38000164  0.138535
# 38000165  0.138535
# 38000166  0.138535
# 38000167  0.138535
# 38000168  0.138535
# 38000169  0.138535
# 38000170  0.138535
# 38000171  0.138535
# 38000172  0.138535
# 38000173  0.138535
# 38000174  0.138535
# 38000175  0.138535
# 38000176  0.138535
# 38000177  0.138535
# 38000178  0.138535
# 38000179  0.138535
# 38000180  0.138535
# 38000181  0.138535
# 38000182  0.138535
# 38000183  0.138535
# 38000184  0.138535
# 38000185  0.138535
# 38000186  0.138535
# 38000187  0.138535
# 38000188  -1.30438
# 38000189  0.138535
# 38000190  0.138535
# 38000191  0.138535
# 38000192  -1.30438
# 38000193  0.138535
# 38000194  -1.30438
# 38000195  0.138535
# 38000196  0.138535
# 38000197  0.138535
# 38000198  0.138535
# 38000199  0.138535
# 38000200  0.138535
# 38000201  0.138535
# 38000202  0.138535
# 38000203  0.138535
# 38000204  0.138535
# 38000205  0.138535
# 38000206  0.138535
# 38000207  0.138535
# 38000208  0.138535
# 38000209  0.138535
# 38000210  0.138535
# 38000211  0.138535
# 38000212  0.138535
# 38000213  0.138535
# 38000214  0.138535
# 38000215  0.138535
# 38000216  0.138535
# 38000217  0.138535
# 38000218  0.138535
# 38000219  0.138535
# 38000220  0.138535
# 38000221  -2.05469
# 38000222  0.138535
# 38000223  0.138535
# 38000224  0.138535
# 38000225  0.138535
# 38000226  0.138535
# 38000227  0.138535
# 38000228  0.138535
# 38000229  0.138535
# 38000230  0.138535
# 38000231  0.138535
# 38000232  0.138535
# 38000233  -1.76611
# 38000234  0.138535
# 38000235  -1.59296
# 38000236  0.138535
# 38000237  0.138535
# 38000238  -1.76611
# 38000239  0.138535
# 38000240  0.138535
# 38000241  0.138535
# 38000242  0.138535
# 38000243  -1.76611
# 38000244  0.138535
# 38000245  0.138535
# 38000246  0.138535
# 38000247  0.138535
# 38000248  0.138535
# 38000249  0.138535
# 38000250  0.138535
# 38000251  0.138535
# 38000252  0.138535
# 38000253  0.138535
# 38000254  0.138535
# 38000255  0.138535
# 38000256  0.138535
# 38000257  0.138535
# 38000258  0.138535
# 38000259  0.138535
# 38000260  0.138535
# 38000261  0.138535
# 38000262  0.138535
# 38000263  0.138535
# 38000264  -1.30438
# 38000265  0.138535
# 38000266  0.138535
# 38000267  -1.62182
# 38000268  0.138535
# 38000269  0.138535
# 38000270  0.138535
# 38000271  0.138535
# 38000272  0.138535
# 38000273  0.138535
# 38000274  0.138535
# 38000275  0.138535
# 38000276  0.138535
# 38000277  0.138535
# 38000278  0.138535
# 38000279  0.138535
# 38000280  0.138535
# 38000281  0.138535
# 38000282  0.138535
# 38000283  0.138535
# 38000284  0.138535
# 38000285  0.138535
# 38000286  -1.76611
# 38000287  0.138535
# 38000288  -1.24666
# 38000289  0.138535
# 38000290  0.138535
# 38000291  0.138535
# 38000292  0.138535
# 38000293  0.138535
# 38000294  0.138535
# 38000295  -1.30438
# 38000296  -1.24666
# 38000297  0.138535
# 38000298  0.138535
# 38000299  0.138535
# 38000300  0.138535
# 38000301  0.138535
# 38000302  0.138535
# 38000303  0.138535
# 38000304  0.138535
# 38000305  0.138535
# 38000306  0.138535
# 38000307  0.138535
# 38000308  0.138535
# 38000309  0.138535
# 38000310  0.138535
# 38000311  0.138535
# 38000312  0.138535
# 38000313  0.138535
# 38000314  0.138535
# 38000315  0.138535
# 38000316  0.138535
# 38000317  0.138535
# 38000318  0.138535
# 38000319  0.138535
# 38000320  0.138535
# 38000321  0.138535
# 38000322  0.138535
# 38000323  0.138535
# 38000324  0.138535
# 38000325  0.138535
# 38000326  0.138535
# 38000327  0.138535
# 38000328  0.138535
# 38000329  -1.67954
# 38000330  0.138535
# 38000331  0.138535
# 38000332  0.138535
# 38000333  0.138535
# 38000334  0.138535
# 38000335  0.138535
# 38000336  0.138535
# 38000337  0.138535
# 38000338  0.138535
# 38000339  0.138535
# 38000340  0.138535
# 38000341  0.138535
# 38000342  0.138535
# 38000343  0.138535
# 38000344  0.138535
# 38000345  -1.24666
# 38000346  0.138535
# 38000347  0.138535
# 38000348  0.138535
# 38000349  0.138535
# 38000350  0.138535
# 38000351  0.138535
# 38000352  0.138535
# 38000353  -1.24666
# 38000354  0.138535
# 38000355  0.138535
# 38000356  -1.30438
# 38000357  0.138535
# 38000358  0.138535
# 38000359  0.138535
# 38000360  0.138535
# 38000361  0.138535
# 38000362  0.138535
# 38000363  0.138535
# 38000364  0.138535
# 38000365  0.138535
# 38000366  0.138535
# 38000367  0.138535
# 38000368  0.138535
# 38000369  0.138535
# 38000370  0.138535
# 38000371  0.138535
# 38000372  0.138535
# 38000373  0.138535
# 38000374  0.138535
# 38000375  0.138535
# 38000376  0.138535
# 38000377  0.138535
# 38000378  0.138535
# 38000379  0.138535
# 38000380  0.138535
# 38000381  0.138535
# 38000382  -1.30438
# 38000383  0.138535
# 38000384  0.138535
# 38000385  0.138535
# 38000386  0.138535
# 38000387  0.138535
# 38000388  0.138535
# 38000389  0.138535
# 38000390  0.138535
# 38000391  0.138535
# 38000392  0.138535
# 38000393  -1.73725
# 38000394  0.138535
# 38000395  0.138535
# 38000396  0.138535
# 38000397  0.138535
# 38000398  0.138535
# 38000399  0.138535
# 38000400  -1.24666
# 38000401  0.138535
# 38000402  0.138535
# 38000403  0.138535
# 38000404  0.138535
# 38000405  0.138535
# 38000406  0.138535
# 38000407  0.138535
# 38000408  0.138535
# 38000409  0.138535
# 38000410  0.138535
# 38000411  0.138535
# 38000412  0.138535
# 38000413  0.138535
# 38000414  0.138535
# 38000415  0.138535
# 38000416  0.138535
# 38000417  -1.47753
# 38000418  0.138535
# 38000419  0.138535
# 38000420  0.138535
# 38000421  0.138535
# 38000422  0.138535
# 38000423  0.138535
# 38000424  0.138535
# 38000425  -1.24666
# 38000426  0.138535
# 38000427  0.138535
# 38000428  0.138535
# 38000429  0.138535
# 38000430  0.138535
# 38000431  0.138535
# 38000432  0.138535
# 38000433  0.138535
# 38000434  0.138535
# 38000435  0.138535
# 38000436  0.138535
# 38000437  0.138535
# 38000438  0.138535
# 38000439  0.138535
# 38000440  0.138535
# 38000441  0.138535
# 38000442  0.138535
# 38000443  0.138535
# 38000444  0.138535
# 38000445  0.138535
# 38000446  0.138535
# 38000447  0.138535
# 38000448  0.138535
# 38000449  0.138535
# 38000450  0.138535
# 38000451  0.138535
# 38000452  0.138535
# 38000453  0.138535
# 38000454  0.138535
# 38000455  0.138535
# 38000456  -1.99698
# 38000457  -1.73725
# 38000458  0.138535
# 38000459  0.0519606
# 38000460  0.0519606
# 38000461  0.156583
# 38000462  0.123323
# 38000463  0.156583
# 38000464  0.123323
# 38000465  0.156583
# 38000466  0.123323
# 38000467  0.156583
# 38000468  0.123323
# 38000469  0.156583
# 38000470  0.123323
# 38000471  0.156583
# 38000472  0.123323
# 38000473  0.156583
# 38000474  0.123323
# 38000475  0.156583
# 38000476  0.123323
# 38000477  0.156583
# 38000478  0.156583
# 38000479  0.156583
# 38000480  0.156583
# 38000481  0.156583
# 38000482  0.156583
# 38000483  0.156583
# 38000484  0.156583
# 38000485  0.156583
# 38000486  0.156583
# 38000487  0.156583
# 38000488  0.156583
# 38000489  -1.53967
# 38000490  0.156583
# 38000491  0.156583
# 38000492  0.156583
# 38000493  0.156583
# 38000494  -1.53967
# 38000495  0.156583
# 38000496  0.156583
# 38000497  0.156583
# 38000498  0.156583
# 38000499  -1.27359
# 38000500  0.156583
# 38000501  -1.53967
# 38000502  -1.30685
# 38000503  0.123323
# 38000504  0.156583
# 38000505  -1.73923
# 38000506  0.123323
# 38000507  0.123323
# 38000508  0.156583
# 38000509  -3.502
# 38000510  0.156583
# 38000511  0.156583
# 38000512  0.156583
# 38000513  0.156583
# 38000514  0.156583
# 38000515  0.156583
# 38000516  0.156583
# 38000517  0.156583
# 38000518  0.123323
# 38000519  0.156583
# 38000520  0.356142
# 38000521  0.356142
# 38000522  0.389402
# 38000523  0.389402
# 38000524  0.322882
# 38000525  0.422661
# 38000526  0.356142
# 38000527  -0.475354
# 38000528  0.389402
# 38000529  0.356142
# 38000530  0.356142
# 38000531  0.422661
# 38000532  0.422661
# 38000533  0.356142
# 38000534  0.322882
# 38000535  0.422661
# 38000536  0.356142
# 38000537  0.389402
# 38000538  0.422661
# 38000539  0.422661
# 38000540  0.389402
# 38000541  0.389402
# 38000542  -0.475354
# 38000543  0.356142
# 38000544  0.422661
# 38000545  -0.508614
# 38000546  0.356142
# 38000547  0.422661
# 38000548  0.356142
# 38000549  0.422661
# 38000550  0.356142
# 38000551  0.356142
# 38000552  0.422661
# 38000553  0.422661
# 38000554  -0.807953
# 38000555  0.422661
# 38000556  0.356142
# 38000557  -0.807953
# 38000558  -0.508614
# 38000559  0.422661
# 38000560  0.422661
# 38000561  0.356142
# 38000562  -0.841213
# 38000563  -0.309055
# 38000564  0.522441
# 38000565  -0.275795
# 38000566  0.588961
# 38000567  0.588961
# 38000568  -0.275795
# 38000569  -0.275795
# 38000570  0.588961
# 38000571  0.522441
# 38000572  0.522441
# 38000573  0.522441
# 38000574  -0.275795
# 38000575  0.65548
# 38000576  -0.375575
# 38000577  0.422661
# 38000578  0.65548
# 38000579  -0.242535
# 38000580  0.588961
# 38000581  -1.30685
# 38000582  -0.575134
# 38000583  -0.475354
# 38000584  0.389402
# 38000585  -0.508614
# 38000586  0.356142
# 38000587  0.389402
# 38000588  0.389402
# 38000589  0.389402
# 38000590  -0.508614
# 38000591  -0.475354
# 38000592  0.356142
# 38000593  0.356142
# 38000594  0.422661
# 38000595  -0.475354
# 38000596  0.422661
# 38000597  0.389402
# 38000598  0.422661
# 38000599  0.356142
# 38000600  0.356142
# 38000601  -0.575134
# 38000602  -0.708173
# 38000603  0.389402
# 38000604  0.422661
# 38000605  0.422661
# 38000606  -0.275795
# 38000607  0.588961
# 38000608  0.489181
# 38000609  0.422661
# 38000610  -0.242535
# 38000611  -1.60619
# 38000612  0.522441
# 38000613  -1.07403
# 38000614  0.588961
# 38000615  -0.375575
# 38000616  -0.708173
# 38000617  0.65548
# 38000618  -0.342315
# 38000619  0.722
# 38000620  0.722
# 38000621  0.722
# 38000622  0.65548
# 38000623  -0.209276
# 38000624  -0.342315
# 38000625  -0.209276
# 38000626  0.722
# 38000627  0.65548
# 38000628  0.65548
# 38000629  0.65548
# 38000630  0.65548
# 38000631  0.65548
# 38000632  -1.34011
# 38000633  0.722
# 38000634  -0.242535
# 38000635  0.588961
# 38000636  -0.575134
# 38000637  0.356142
# 38000638  -0.209276
# 38000639  -0.242535
# 38000640  -0.874472
# 38000641  0.65548
# 38000642  -0.209276
# 38000643  -0.275795
# 38000644  0.722
# 38000645  0.722
# 38000646  0.722
# 38000647  -0.176016
# 38000648  0.65548
# 38000649  0.588961
# 38000650  0.65548
# 38000651  0.588961
# 38000652  -0.309055
# 38000653  0.65548
# 38000654  -0.142756
# 38000655  0.62222
# 38000656  -0.309055
# 38000657  0.722
# 38000658  0.722
# 38000659  0.722
# 38000660  0.62222
# 38000661  0.588961
# 38000662  -0.242535
# 38000663  -0.541874
# 38000664  0.489181
# 38000665  -0.275795
# 38000666  0.62222
# 38000667  -0.275795
# 38000668  -0.309055
# 38000669  -0.142756
# 38000670  -0.142756
# 38000671  -0.176016
# 38000672  0.62222
# 38000673  0.722
# 38000674  0.588961
# 38000675  0.65548
# 38000676  0.588961
# 38000677  -0.242535
# 38000678  0.588961
# 38000679  -0.375575
# 38000680  -0.242535
# 38000681  0.588961
# 38000682  0.588961
# 38000683  -1.10729
# 38000684  -0.242535
# 38000685  0.588961
# 38000686  0.156583
# 38000687  0.156583
# 38000688  0.156583
# 38000689  -1.73923
# 38000690  -1.30685
# 38000691  -1.30685
# 38000692  -1.30685
# 38000693  0.123323
# 38000694  0.123323
# 38000695  0.156583
# 38000696  0.123323
# 38000697  0.156583
# 38000698  0.156583
# 38000699  0.123323
# 38000700  0.123323
# 38000701  0.156583
# 38000702  0.156583
# 38000703  -1.27359
# 38000704  0.123323
# 38000705  -2.13835
# 38000706  0.123323
# 38000707  0.156583
# 38000708  0.156583
# 38000709  0.123323
# 38000710  0.123323
# 38000711  0.156583
# 38000712  0.156583
# 38000713  0.156583
# 38000714  0.422661
# 38000715  0.356142
# 38000716  0.422661
# 38000717  0.322882
# 38000718  0.389402
# 38000719  0.389402
# 38000720  -0.541874
# 38000721  0.422661
# 38000722  0.422661
# 38000723  0.422661
# 38000724  0.356142
# 38000725  -0.807953
# 38000726  0.356142
# 38000727  -0.807953
# 38000728  -0.508614
# 38000729  0.422661
# 38000730  0.422661
# 38000731  0.422661
# 38000732  0.422661
# 38000733  0.156583
# 38000734  -0.508614
# 38000735  0.389402
# 38000736  0.322882
# 38000737  -1.07403
# 38000738  0.322882
# 38000739  0.389402
# 38000740  0.156583
# 38000741  0.123323
# 38000742  0.123323
# 38000743  0.322882
# 38000744  0.322882
# 38000745  0.422661
# 38000746  0.322882
# 38000747  0.389402
# 38000748  0.389402
# 38000749  0.322882
# 38000750  0.389402
# 38000751  0.322882
# 38000752  0.389402
# 38000753  -1.24033
# 38000754  0.389402
# 38000755  0.422661
# 38000756  -0.541874
# 38000757  0.422661
# 38000758  0.322882
# 38000759  0.422661
# 38000760  0.389402
# 38000761  -0.508614
# 38000762  0.322882
# 38000763  -0.541874
# 38000764  -0.508614
# 38000765  -0.807953
# 38000766  -0.807953
# 38000767  -0.475354
# 38000768  0.422661
# 38000769  0.422661
# 38000770  0.422661
# 38000771  0.422661
# 38000772  0.422661
# 38000773  0.422661
# 38000774  0.422661
# 38000775  0.356142
# 38000776  0.422661
# 38000777  0.322882
# 38000778  0.389402
# 38000779  0.356142
# 38000780  0.356142
# 38000781  0.422661
# 38000782  0.422661
# 38000783  0.356142
# 38000784  0.356142
# 38000785  0.422661
# 38000786  0.422661
# 38000787  0.422661
# 38000788  0.389402
# 38000789  -0.508614
# 38000790  0.422661
# 38000791  0.422661
# 38000792  0.322882
# 38000793  0.322882
# 38000794  0.422661
# 38000795  0.422661
# 38000796  -0.541874
# 38000797  -0.508614
# 38000798  0.389402
# 38000799  0.322882
# 38000800  0.389402
# 38000801  0.389402
# 38000802  -1.24033
# 38000803  0.422661
# 38000804  0.322882
# 38000805  0.422661
# 38000806  0.356142
# 38000807  0.389402
# 38000808  -0.974252
# 38000809  0.356142
# 38000810  0.389402
# 38000811  0.389402
# 38000812  -0.508614
# 38000813  -0.575134
# 38000814  0.322882
# 38000815  0.322882
# 38000816  0.389402
# 38000817  0.389402
# 38000818  0.389402
# 38000819  0.356142
# 38000820  0.356142
# 38000821  0.389402
# 38000822  0.356142
# 38000823  0.356142
# 38000824  0.356142
# 38000825  0.356142
# 38000826  0.422661
# 38000827  0.356142
# 38000828  0.422661
# 38000829  -0.807953
# 38000830  -1.24033
# 38000831  0.422661
# 38000832  0.389402
# 38000833  0.356142
# 38000834  -0.475354
# 38000835  -0.508614
# 38000836  0.389402
# 38000837  0.422661
# 38000838  0.422661
# 38000839  -1.27359
# 38000840  0.389402
# 38000841  -2.53746
# 38000842  0.389402
# 38000843  -0.807953
# 38000844  0.389402
# 38000845  0.156583
# 38000846  0.156583
# 38000847  0.389402
# 38000848  0.322882
# 38000849  0.389402
# 38000850  0.389402
# 38000851  -0.575134
# 38000852  0.389402
# 38000853  0.389402
# 38000854  0.389402
# 38000855  0.356142
# 38000856  -0.541874
# 38000857  0.422661
# 38000858  0.322882
# 38000859  0.422661
# 38000860  0.389402
# 38000861  0.389402
# 38000862  0.389402
# 38000863  0.422661
# 38000864  0.389402
# 38000865  -0.807953
# 38000866  -1.20707
# 38000867  0.389402
# 38000868  0.322882
# 38000869  0.322882
# 38000870  0.422661
# 38000871  0.422661
# 38000872  0.356142
# 38000873  0.389402
# 38000874  0.389402
# 38000875  0.389402
# 38000876  0.389402
# 38000877  -2.60398
# 38000878  -0.541874
# 38000879  -1.04077
# 38000880  0.389402
# 38000881  0.422661
# 38000882  0.389402
# 38000883  -0.475354
# 38000884  -0.541874
# 38000885  -2.37117
# 38000886  0.389402
# 38000887  0.422661
# 38000888  0.389402
# 38000889  0.422661
# 38000890  0.123323
# 38000891  0.156583
# 38000892  -0.00971653
# 38000893  -0.00971653
# 38000894  -0.00971653
# 38000895  0.356142
# 38000896  0.356142
# 38000897  0.356142
# 38000898  0.356142
# 38000899  -0.674913
# 38000900  0.389402
# 38000901  -1.77249
# 38000902  0.389402
# 38000903  -0.907732
# 38000904  0.389402
# 38000905  -0.641654
# 38000906  0.389402
# 38000907  0.356142
# 38000908  0.389402
# 38000909  0.356142
# 38000910  0.389402
# 38000911  -0.974252
# 38000912  0.322882
# 38000913  0.389402
# 38000914  -1.77249
# 38000915  0.389402
# 38000916  -0.907732
# 38000917  0.389402
# 38000918  -0.641654
# 38000919  0.389402
# 38000920  -1.00751
# 38000921  0.389402
# 38000922  0.389402
# 38000923  -1.00751
# 38000924  0.389402
# 38000925  -0.907732
# 38000926  0.389402
# 38000927  0.356142
# 38000928  0.389402
# 38000929  0.356142
# 38000930  -0.575134
# 38000931  0.356142
# 38000932  -0.907732
# 38000933  0.389402
# 38000934  -1.00751
# 38000935  0.389402
# 38000936  -2.77028
# 38000937  0.389402
# 38000938  0.356142
# 38000939  -0.907732
# 38000940  -0.907732
# 38000941  0.389402
# 38000942  -0.907732
# 38000943  0.322882
# 38000944  0.389402
# 38000945  -0.641654
# 38000946  0.389402
# 38000947  -1.00751
# 38000948  -0.575134
# 38000949  -0.575134
# 38000950  0.322882
# 38000951  0.389402
# 38000952  0.322882
# 38000953  -0.907732
# 38000954  -0.641654
# 38000955  -0.575134
# 38000956  -1.00751
# 38000957  -1.80575
# 38000958  0.356142
# 38000959  0.389402
# 38000960  0.389402
# 38000961  0.322882
# 38000962  -0.907732
# 38000963  0.322882
# 38000964  0.389402
# 38000965  0.356142
# 38000966  0.389402
# 38000967  0.0568031
# 38000968  0.0568031
# 38000969  0.0568031
# 38000970  0.0568031
# 38000971  0.0568031
# 38000972  0.0568031
# 38000973  0.0568031
# 38000974  -2.07183
# 38000975  0.0568031
# 38000976  0.0568031
# 38000977  0.0568031
# 38000978  0.0568031
# 38000979  -2.43769
# 38000980  0.0568031
# 38000981  0.0568031
# 38000982  0.0568031
# 38000983  0.0568031
# 38000984  0.0568031
# 38000985  0.0568031
# 38000986  0.0568031
# 38000987  0.0568031
# 38000988  0.0568031
# 38000989  0.0568031
# 38000990  0.0568031
# 38000991  0.0568031
# 38000992  -2.43769
# 38000993  -2.33791
# 38000994  -2.43769
# 38000995  0.0568031
# 38000996  0.0568031
# 38000997  0.0568031
# 38000998  0.0568031
# 38000999  0.0568031
# 38001000  0.0568031
# 38001001  -2.37117
# 38001002  -2.33791
# 38001003  -2.07183
# 38001004  0.0568031
# 38001005  -2.37117
# 38001006  -2.33791
# 38001007  -2.07183
# 38001008  0.0568031
# 38001009  -2.07183
# 38001010  0.0568031
# 38001011  0.0568031
# 38001012  0.0568031
# 38001013  0.0568031
# 38001014  0.0568031
# 38001015  0.0568031
# 38001016  0.0568031
# 38001017  0.0568031
# 38001018  0.0568031
# 38001019  0.0568031
# 38001020  0.0568031
# 38001021  0.0568031
# 38001022  0.0568031
# 38001023  0.0568031
# 38001024  0.0568031
# 38001025  0.0568031
# 38001026  0.0568031
# 38001027  0.0568031
# 38001028  -2.13835
# 38001029  0.0568031
# 38001030  0.0568031
# 38001031  0.0568031
# 38001032  0.0568031
# 38001033  0.0568031
# 38001034  0.0568031
# 38001035  0.0568031
# 38001036  0.0568031
# 38001037  0.0568031
# 38001038  0.0568031
# 38001039  -2.13835
# 38001040  0.0568031
# 38001041  0.0568031
# 38001042  0.0568031
# 38001043  0.0568031
# 38001044  0.0568031
# 38001045  0.0568031
# 38001046  0.0568031
# 38001047  0.0568031
# 38001048  0.0568031
# 38001049  0.0568031
# 38001050  0.0568031
# 38001051  0.0568031
# 38001052  -2.07183
# 38001053  0.0568031
# 38001054  0.0568031
# 38001055  0.0568031
# 38001056  0.0568031
# 38001057  0.0568031
# 38001058  0.0568031
# 38001059  0.0568031
# 38001060  0.0568031
# 38001061  0.0568031
# 38001062  0.0568031
# 38001063  0.0568031
# 38001064  0.0568031
# 38001065  0.0568031
# 38001066  0.0568031
# 38001067  0.0568031
# 38001068  0.0568031
# 38001069  0.0568031
# 38001070  0.0568031
# 38001071  0.0568031
# 38001072  0.0568031
# 38001073  0.0568031
# 38001074  0.0568031
# 38001075  0.0568031
# 38001076  0.0568031
# 38001077  0.0568031
# 38001078  0.0568031
# 38001079  0.0568031
# 38001080  0.0568031
# 38001081  0.0568031
# 38001082  0.0568031
# 38001083  0.0568031
# 38001084  0.0568031
# 38001085  0.156583
# 38001086  0.156583
# 38001087  0.156583
# 38001088  0.123323
# 38001089  0.156583
# 38001090  0.156583
# 38001091  0.123323
# 38001092  0.156583
# 38001093  0.156583
# 38001094  0.156583
# 38001095  0.123323
# 38001096  0.156583
# 38001097  0.156583
# 38001098  0.156583
# 38001099  0.156583
# 38001100  0.156583
# 38001101  -0.575134
# 38001102  0.422661
# 38001103  -0.508614
# 38001104  -0.508614
# 38001105  0.422661
# 38001106  0.422661
# 38001107  0.422661
# 38001108  0.422661
# 38001109  0.422661
# 38001110  -0.708173
# 38001111  -0.508614
# 38001112  -0.708173
# 38001113  -0.708173
# 38001114  0.422661
# 38001115  0.422661
# 38001116  0.422661
# 38001117  0.422661
# 38001118  0.422661
# 38001119  -0.508614
# 38001120  -0.708173
# 38001121  0.389402
# 38001122  0.422661
# 38001123  -0.475354

######################## The test ########################
# @phyloP7way = (0.138535,0.138535,0.138535,0.138535,0.138535,-1.24666,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.24666,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.59296,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.30438,0.138535,0.138535,0.138535,-1.30438,0.138535,-1.30438,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-2.05469,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.76611,0.138535,-1.59296,0.138535,0.138535,-1.76611,0.138535,0.138535,0.138535,0.138535,-1.76611,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.30438,0.138535,0.138535,-1.62182,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.76611,0.138535,-1.24666,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.30438,-1.24666,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.67954,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.24666,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.24666,0.138535,0.138535,-1.30438,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.30438,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.73725,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.24666,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.47753,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.24666,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,0.138535,-1.99698,-1.73725,0.138535,0.0519606,0.0519606,0.156583,0.123323,0.156583,0.123323,0.156583,0.123323,0.156583,0.123323,0.156583,0.123323,0.156583,0.123323,0.156583,0.123323,0.156583,0.123323,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,-1.53967,0.156583,0.156583,0.156583,0.156583,-1.53967,0.156583,0.156583,0.156583,0.156583,-1.27359,0.156583,-1.53967,-1.30685,0.123323,0.156583,-1.73923,0.123323,0.123323,0.156583,-3.502,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.156583,0.123323,0.156583,0.356142,0.356142,0.389402,0.389402,0.322882,0.422661,0.356142,-0.475354,0.389402,0.356142,0.356142,0.422661,0.422661,0.356142,0.322882,0.422661,0.356142,0.389402,0.422661,0.422661,0.389402,0.389402,-0.475354,0.356142,0.422661,-0.508614,0.356142,0.422661,0.356142,0.422661,0.356142,0.356142,0.422661,0.422661,-0.807953,0.422661,0.356142,-0.807953,-0.508614,0.422661,0.422661,0.356142,-0.841213,-0.309055,0.522441,-0.275795,0.588961,0.588961,-0.275795,-0.275795,0.588961,0.522441,0.522441,0.522441,-0.275795,0.65548,-0.375575,0.422661,0.65548,-0.242535,0.588961,-1.30685,-0.575134,-0.475354,0.389402,-0.508614,0.356142,0.389402,0.389402,0.389402,-0.508614,-0.475354,0.356142,0.356142,0.422661,-0.475354,0.422661,0.389402,0.422661,0.356142,0.356142,-0.575134,-0.708173,0.389402,0.422661,0.422661,-0.275795,0.588961,0.489181,0.422661,-0.242535,-1.60619,0.522441,-1.07403,0.588961,-0.375575,-0.708173,0.65548,-0.342315,0.722,0.722,0.722,0.65548,-0.209276,-0.342315,-0.209276,0.722,0.65548,0.65548,0.65548,0.65548,0.65548,-1.34011,0.722,-0.242535,0.588961,-0.575134,0.356142,-0.209276,-0.242535,-0.874472,0.65548,-0.209276,-0.275795,0.722,0.722,0.722,-0.176016,0.65548,0.588961,0.65548,0.588961,-0.309055,0.65548,-0.142756,0.62222,-0.309055,0.722,0.722,0.722,0.62222,0.588961,-0.242535,-0.541874,0.489181,-0.275795,0.62222,-0.275795,-0.309055,-0.142756,-0.142756,-0.176016,0.62222,0.722,0.588961,0.65548,0.588961,-0.242535,0.588961,-0.375575,-0.242535,0.588961,0.588961,-1.10729,-0.242535,0.588961,0.156583,0.156583,0.156583,-1.73923,-1.30685,-1.30685,-1.30685,0.123323,0.123323,0.156583,0.123323,0.156583,0.156583,0.123323,0.123323,0.156583,0.156583,-1.27359,0.123323,-2.13835,0.123323,0.156583,0.156583,0.123323,0.123323,0.156583,0.156583,0.156583,0.422661,0.356142,0.422661,0.322882,0.389402,0.389402,-0.541874,0.422661,0.422661,0.422661,0.356142,-0.807953,0.356142,-0.807953,-0.508614,0.422661,0.422661,0.422661,0.422661,0.156583,-0.508614,0.389402,0.322882,-1.07403,0.322882,0.389402,0.156583,0.123323,0.123323,0.322882,0.322882,0.422661,0.322882,0.389402,0.389402,0.322882,0.389402,0.322882,0.389402,-1.24033,0.389402,0.422661,-0.541874,0.422661,0.322882,0.422661,0.389402,-0.508614,0.322882,-0.541874,-0.508614,-0.807953,-0.807953,-0.475354,0.422661,0.422661,0.422661,0.422661,0.422661,0.422661,0.422661,0.356142,0.422661,0.322882,0.389402,0.356142,0.356142,0.422661,0.422661,0.356142,0.356142,0.422661,0.422661,0.422661,0.389402,-0.508614,0.422661,0.422661,0.322882,0.322882,0.422661,0.422661,-0.541874,-0.508614,0.389402,0.322882,0.389402,0.389402,-1.24033,0.422661,0.322882,0.422661,0.356142,0.389402,-0.974252,0.356142,0.389402,0.389402,-0.508614,-0.575134,0.322882,0.322882,0.389402,0.389402,0.389402,0.356142,0.356142,0.389402,0.356142,0.356142,0.356142,0.356142,0.422661,0.356142,0.422661,-0.807953,-1.24033,0.422661,0.389402,0.356142,-0.475354,-0.508614,0.389402,0.422661,0.422661,-1.27359,0.389402,-2.53746,0.389402,-0.807953,0.389402,0.156583,0.156583,0.389402,0.322882,0.389402,0.389402,-0.575134,0.389402,0.389402,0.389402,0.356142,-0.541874,0.422661,0.322882,0.422661,0.389402,0.389402,0.389402,0.422661,0.389402,-0.807953,-1.20707,0.389402,0.322882,0.322882,0.422661,0.422661,0.356142,0.389402,0.389402,0.389402,0.389402,-2.60398,-0.541874,-1.04077,0.389402,0.422661,0.389402,-0.475354,-0.541874,-2.37117,0.389402,0.422661,0.389402,0.422661,0.123323,0.156583,-0.00971653,-0.00971653,-0.00971653,0.356142,0.356142,0.356142,0.356142,-0.674913,0.389402,-1.77249,0.389402,-0.907732,0.389402,-0.641654,0.389402,0.356142,0.389402,0.356142,0.389402,-0.974252,0.322882,0.389402,-1.77249,0.389402,-0.907732,0.389402,-0.641654,0.389402,-1.00751,0.389402,0.389402,-1.00751,0.389402,-0.907732,0.389402,0.356142,0.389402,0.356142,-0.575134,0.356142,-0.907732,0.389402,-1.00751,0.389402,-2.77028,0.389402,0.356142,-0.907732,-0.907732,0.389402,-0.907732,0.322882,0.389402,-0.641654,0.389402,-1.00751,-0.575134,-0.575134,0.322882,0.389402,0.322882,-0.907732,-0.641654,-0.575134,-1.00751,-1.80575,0.356142,0.389402,0.389402,0.322882,-0.907732,0.322882,0.389402,0.356142,0.389402,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,-2.07183,0.0568031,0.0568031,0.0568031,0.0568031,-2.43769,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,-2.43769,-2.33791,-2.43769,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,-2.37117,-2.33791,-2.07183,0.0568031,-2.37117,-2.33791,-2.07183,0.0568031,-2.07183,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,-2.13835,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,-2.13835,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,-2.07183,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.0568031,0.156583,0.156583,0.156583,0.123323,0.156583,0.156583,0.123323,0.156583,0.156583,0.156583,0.123323,0.156583,0.156583,0.156583,0.156583,0.156583,-0.575134,0.422661,-0.508614,-0.508614,0.422661,0.422661,0.422661,0.422661,0.422661,-0.708173,-0.508614,-0.708173,-0.708173,0.422661,0.422661,0.422661,0.422661,0.422661,-0.508614,-0.708173,0.389402,0.422661,-0.475354);

# @positions = ( 38000123 - 1 .. 38001123 - 1 );
# @dbData = @positions;
# $db->dbRead('chr19', \@dbData);

# $inputAref = [];

# for my $i ( 0 .. $#positions) {
#   my $refBase = $refTrackGetter->get( $dbData[$i] );
#   push @$inputAref, ['chf19', $positions[$i], $refBase, '-1', 'SNP', $refBase, 1, 'D', 1]
# }

# ($annotator->{_genoNames}, $annotator->{_genosIdx}, $annotator->{_confIdx}) = 
#   (["Sample_4", "Sample_5"], [5, 7], [6, 8]);

# $annotator->{_genosIdxRange} = [0, 1];


# $outAref = [];

# $annotator->addTrackData('chr19', \@dbData, $inputAref, $outAref);

# $i = 0;
# for my $data (@$outAref) {
#   my $phyloPdata = $data->[$trackIndices->{phyloP}][0][0];
#   my $ucscRounded = $rounder->round($phyloP7way[$i]);

#   ok($phyloPdata == $ucscRounded, "chr19\:$positions[$i]: our phyloP score: $phyloPdata ; theirs: $ucscRounded ; exact: $phyloP7way[$i]");
#   $i++;
# }

say "\n Testing rounder functionality \n";
ok ($rounder->round(.068) + 0 == .07, "rounds up above midpoint");
ok ($rounder->round(.063) + 0 == .06, "rounds down below midpoint");
ok ($rounder->round(.065) + 0 == .07, "rounds up at midpoint");
ok ($rounder->round(-0.475354) + 0 == -0.48, "rounds negative numbers");
