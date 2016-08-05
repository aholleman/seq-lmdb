use 5.10.0;
use strict;
use warnings;

package Seq::Statistics;
use Mouse 2;

use Sort::XS;
use Seq::Tracks;
use DDP;
use List::Util qw/reduce/;

with 'Seq::Role::ConfigFromFile', 'Seq::Role::IO';

my $siteHandler = Seq::Tracks::Gene::Site->new();

# From YAML config, the gene track and snp track whose features we take ratios of
has gene_track => (is => 'ro', isa => 'Str', required => 1);
has snp_track => (is => 'ro', isa => 'Str', required => 1);

# We need to konw where the heterozygotes homozygotes, and minor alleles are located
has heterozygoteIdsKey =>  (is => 'ro', isa => 'Str', required => 1);
has homozygoteIdsKey =>  (is => 'ro', isa => 'Str', required => 1);
has minorAllelesKey => (is => 'ro', isa => 'Str', required => 1);

my %transitionGenos = (AG => 1, GA => 1, CT => 1, TC => 1);

my $siteTypeKey = $siteHandler->siteTypeKey;
my $transitionsKey = 'Transitions';
my $transversionsKey = 'Transversions';
my $trTvRatioKey = 'Transitions:Transversions Ratio';
my $totalKey = 'Total';
my $dbSnpKey = '-DbSNP';

# cache the names, avoid lookup time
my ($refTrack, $geneTrack, $geneTrackName, $snpTrackName, $hetKey, $homKey, $alleleKey);
sub BUILD{
  my ($self) = @_;

  $hetKey = $self->heterozygoteIdsKey;
  $homKey = $self->homozygoteIdsKey;
  $alleleKey = $self->minorAllelesKey;

  my $tracks = Seq::Tracks->new();
  $refTrack = $tracks->getRefTrackGetter;

  $geneTrackName = $self->gene_track;
  $snpTrackName = $self->snp_track;

  # we need this to get the txEffectsKey
  $geneTrack = $tracks->getTrackGetterByName($geneTrackName);
}

# Take data for a single position and generate trTv statistics
sub countTransitionsAndTransversions {
  my ($self, $outputLinesAref ) = @_;

  my (%transitions, %transversions);

  OUTPUT_LOOP: foreach (@$outputLinesAref) {
    my $sampleIds;
    if( $_->{$hetKey} && $_->{$homKey}) {
      $sampleIds = [ref $_->{$hetKey} ? @{ $_->{$hetKey} } : $_->{$hetKey},
        ref $_->{$hetKey} ? @{ $_->{$homKey} } : $_->{$homKey}];
    } elsif($_->{$hetKey}) {
      $sampleIds = $_->{$hetKey};
    } elsif($_->{$homKey}) {
      $sampleIds = $_->{$homKey};
    } else {
      $self->log('warn', "No samples found in countTransitionsAndTransversions");
      next OUTPUT_LOOP;
    }
    
    my $isTrans = 0;
    my $hasRs;

    my $reference = $_->{$refTrack->name};
    my $minorAlleles = $_->{$alleleKey};

    # We don't include multi-allelic sites for now
    if(ref $minorAlleles || ! $minorAlleles =~ /ACTG/) {
      next OUTPUT_LOOP;
    }

    if(!defined $transitions{$totalKey}{$totalKey}) {
      $transitions{$totalKey}{$totalKey} = 0;
    }

    if(!defined $transversions{$totalKey}{$totalKey} ) {
      $transversions{$totalKey}{$totalKey} = 0;
    }

    # The alleles field is always ACTG, and doesn't include the reference
    if( $transitionGenos{"$minorAlleles$reference"} ){
      $isTrans = 1;

      #Store the transitions and transversions totals once to avoid N-counting
      $transitions{$totalKey}{$totalKey}++;
    } else {
      $transversions{$totalKey}{$totalKey}++;
    }

    # The presence of a dbSNP name indicates a dbSNP record (aka hasRs)
    if( $_->{$snpTrackName}{name} ) {
      $hasRs = 1;
    }

    # For every unique site type, count whether this position is a transition or transversion
    my %notUniqueSiteType;
    my $allSites = $_->{$geneTrackName}{$siteTypeKey};

    SITE_TYPE_LOOP: for my $siteType (ref $allSites ? @{$allSites} : $allSites) {
      if(defined $notUniqueSiteType{$siteType} ) { next SITE_TYPE_LOOP; }

      $notUniqueSiteType{$siteType} = 1;

      if(!defined $transitions{$totalKey}{$siteType}) {
        $transitions{$totalKey}{$siteType} = 0;
        $transversions{$totalKey}{$siteType} = 0;
      }

      if($isTrans) { $transitions{$totalKey}{$siteType}++; }
      else { $transversions{$totalKey}{$siteType}++; }

      if($hasRs) {
        if(!defined $transitions{$totalKey}{"$siteType$dbSnpKey"}) {
          $transitions{$totalKey}{"$siteType$dbSnpKey"} = 0;
          $transversions{$totalKey}{"$siteType$dbSnpKey"} = 0;
        }

        if($isTrans) { $transitions{$totalKey}{"$siteType$dbSnpKey"}++; }
        else { $transversions{$totalKey}{"$siteType$dbSnpKey"}++; }
      }

      SAMPLE_LOOP: for my $sampleId (ref $sampleIds ? @$sampleIds : $sampleIds) {
        if(!defined $transitions{$sampleId}{$siteType}) {
          $transitions{$sampleId}{$siteType} = 0;
          $transversions{$sampleId}{$siteType} = 0;
        }

        if($hasRs && !defined $transitions{$sampleId}{"$siteType$dbSnpKey"}) {
          $transitions{$sampleId}{"$siteType$dbSnpKey"} = 0;
          $transversions{$sampleId}{"$siteType$dbSnpKey"} = 0;
        }

        if($isTrans) {
          $transitions{$sampleId}{$siteType}++;
          if($hasRs) { $transitions{$sampleId}{"$siteType$dbSnpKey"}++; }
        } else {
          $transversions{$sampleId}{$siteType}++;
          if($hasRs) { $transversions{$sampleId}{"$siteType$dbSnpKey"}++; }
        }
      }
    }

    # Likewise, for every unique txEffect type, count whether this position is a transition or transversion
    if(!defined $_->{$geneTrackName}{$geneTrack->txEffectsKey} ) {
      next OUTPUT_LOOP;
    }

    my %notUniqueTxEffectType;
    my $allTxEffects = $_->{$geneTrackName}{$geneTrack->txEffectsKey};

    TX_EFFECT_LOOP: for my $txEffect (ref $allTxEffects ? @{$allTxEffects} : $allTxEffects) {
      if(defined $notUniqueTxEffectType{$txEffect} ) { next TX_EFFECT_LOOP; }

      $notUniqueTxEffectType{$txEffect} = 1;

      if(!defined $transitions{$totalKey}{$txEffect}) {
        $transitions{$totalKey}{$txEffect} = 0;
        $transversions{$totalKey}{$txEffect} = 0;
      }

      if($isTrans) { $transitions{$totalKey}{$txEffect}++; }
      else { $transversions{$totalKey}{$txEffect}++; }

      if( $hasRs ) {
        if(!defined $transitions{$totalKey}{"$txEffect$dbSnpKey"}) {
          $transitions{$totalKey}{"$txEffect$dbSnpKey"} = 0;
          $transversions{$totalKey}{"$txEffect$dbSnpKey"} = 0;
        }

        if($isTrans) { $transitions{$totalKey}{"$txEffect$dbSnpKey"}++; }
        else { $transversions{$totalKey}{"$txEffect$dbSnpKey"}++; }
      }

      SAMPLE_LOOP: for my $sampleId (ref $sampleIds ? @$sampleIds : $sampleIds) {
        if(!defined $transitions{$sampleId}{$txEffect}) {
          $transitions{$sampleId}{$txEffect} = 0;
          $transversions{$sampleId}{$txEffect} = 0;
        }

        if($hasRs && !defined $transitions{$sampleId}{"$txEffect$dbSnpKey"}) {
          $transitions{$sampleId}{"$txEffect$dbSnpKey"} = 0;
          $transversions{$sampleId}{"$txEffect$dbSnpKey"} = 0;
        }

        if($isTrans) {
          $transitions{$sampleId}{$txEffect}++;
          if($hasRs) { $transitions{$sampleId}{"$txEffect$dbSnpKey"}++; }
        } else {
          $transversions{$sampleId}{$txEffect}++;
          if($hasRs) { $transversions{$sampleId}{"$txEffect$dbSnpKey"}++; }
        }
      }
    }
  }

  return {
    transitions => \%transitions,
    transversions => \%transversions,
  }
}

# Seperate processes/threads may build up results, we may want to combine the totals
# Updates allHref in place
sub accumulateValues {
  my ($self, $allHref, $addHref) = @_;
  
  # transition, transversion
  for my $trOrTvKey (keys %$addHref) {
    # total or a sampleId
    for my $sampleId (keys %{ $addHref->{$trOrTvKey} } ) {
      # total or site types or txEffect or intersectio of site/txEffect with dbSnpKey
      for my $siteType (keys %{ $addHref->{$trOrTvKey}{$sampleId} } ) {
        if( !defined $allHref->{$trOrTvKey}{$sampleId}{$siteType} ) {
          $allHref->{$trOrTvKey}{$sampleId}{$siteType} = $addHref->{$trOrTvKey}{$sampleId}{$siteType};
          next;
        }

        $allHref->{$trOrTvKey}{$sampleId}{$siteType} += $addHref->{$trOrTvKey}{$sampleId}{$siteType};
      }
    }
  }
}

sub makeRatios {
  my ($self, $allHref) = @_;

  my %ratios;
  my %qualityControl;
  
  my $transitions = $allHref->{transitions};
  my $transversions = $allHref->{transversions};

  # These are the total Tr and Tv for each sample, used for qc measures
  my %sampleTotalTransitions;
  my %sampleTotalTransversions;
  my @allSampleRatios;

  # total or sampleId
  for my $sampleId (keys %$transitions) {
    # site type
    for my $siteType (keys %{ $transitions->{$sampleId} } ) {
      if($transversions->{$sampleId}{$siteType} > 0) {
        $ratios{$sampleId}{"$siteType $trTvRatioKey"} = sprintf "%0.2f",
          $transitions->{$sampleId}{$siteType} / $transversions->{$sampleId}{$siteType};
      }

      if(!defined $sampleTotalTransitions{$sampleId}) {
        $sampleTotalTransitions{$sampleId} = 0;
        $sampleTotalTransversions{$sampleId} = 0;
      }

      $sampleTotalTransitions{$sampleId} += $transitions->{$sampleId}{$siteType};
      $sampleTotalTransversions{$sampleId} += $transversions->{$sampleId}{$siteType};
    }
  }

  # Make the ratios for totalKey and all sampleIds, and record counts of tr & tv
  for my $sampleId (keys %sampleTotalTransitions) {
    if($sampleTotalTransversions{$sampleId} > 0) {
      $ratios{$sampleId}{$trTvRatioKey} = sprintf "%0.2f",
        $sampleTotalTransitions{$sampleId} / $sampleTotalTransversions{$sampleId};

      $ratios{$sampleId}{$transitionsKey} = $sampleTotalTransitions{$sampleId};
      $ratios{$sampleId}{$transversionsKey} = $sampleTotalTransversions{$sampleId};

      if($sampleId eq $totalKey) { 
        next;
      }

      # Store individual sample ratios for SD and Mean calculations
      push @allSampleRatios, $ratios{$sampleId}{$trTvRatioKey};
    }
  }

  my $mean = $self->_mean(\@allSampleRatios);
  my $standardDev = $self->_stDev(\@allSampleRatios, $mean);

  my $threeSd = 3*$standardDev;

  $qualityControl{stats}{Mean} = $mean;
  $qualityControl{stats}{'Standard Deviation'} = $standardDev;

  for my $sampleId (keys %sampleTotalTransitions) {
    if(abs($ratios{$sampleId}{$trTvRatioKey} - $mean) > $threeSd) {
      $qualityControl{fail}{$sampleId} = ">3SD";
    }
  }

  return {ratios => \%ratios, qc => \%qualityControl};
}

sub printStatistics {
  my ($self, $statsHref, $outputFilePath) = @_;

  my $ratiosHref = $statsHref->{ratios};
  my $qcHref = $statsHref->{qc};

  my $ratiosExt = '.stats.ratios.csv';
  my $qcExt = '.stats.qc.csv';

  ############## Print ratios, Total row being first below header ##############
  my %headerRatios = ($transitionsKey => 1, $transversionsKey => 1, $trTvRatioKey => 1);
  my @orderedHeaderRatios;

  for my $ratioType ( @{ Sort::XS::quick_sort_str( [keys %{$ratiosHref->{$totalKey} }] ) } ) {
    if(defined $headerRatios{$ratioType}) {
      next;
    }

    push @orderedHeaderRatios, $ratioType;
    $headerRatios{$ratioType} = 1;
  }

  @orderedHeaderRatios = (@orderedHeaderRatios, $transitionsKey, $transversionsKey, $trTvRatioKey);

  my $fh = $self->get_write_fh($outputFilePath . $ratiosExt);

  say $fh join("\t", @orderedHeaderRatios);

  say $fh "$totalKey\t" . join("\t", map { $ratiosHref->{$totalKey}{$_} } @orderedHeaderRatios);

  for my $sampleId ( @{  Sort::XS::quick_sort_str( [keys %$ratiosHref] ) } ) {
    if($sampleId eq $totalKey) {
      next;
    }

    say $fh "$sampleId\t" . join("\t", map { $ratiosHref->{$sampleId}{$_} } @orderedHeaderRatios);
  }

  close $fh;

  ###################### Print Quality Contorl Information #####################
  $fh = $self->get_write_fh($outputFilePath . $qcExt);

  say $fh "#Mean\t$qcHref->{stats}{Mean}\n".
          "#SD\t$qcHref->{stats}{'Standard Deviation'}";

  close $fh;

  if(!defined $qcHref->{fail}) {
    return;
  }

  say $fh "#Failures\nSampleID\tReason";
  for my $sampleId (keys %{ $qcHref->{fail} }) {
    say $fh "$sampleId\t$qcHref->{fail}{$sampleId}";
  }
}

#https://edwards.sdsu.edu/research/calculating-the-average-and-standard-deviation/
sub _mean{
  my($self, $data) = @_;
  if (!@$data) {
    $self->log('fatal', "Data required in _mean");
  }

  my $total = 0;
  foreach (@$data) {
    $total += $_;
  }
  my $average = $total / @$data;
  return $average;
}
sub _stDev{
  my($self, $data, $average) = @_;
  if(@$data == 1) {
    return 0;
  }

  my $sqtotal = 0;
  foreach(@$data) {
    $sqtotal += ($average-$_) ** 2;
  }
  my $std = ($sqtotal / (@$data-1)) ** 0.5;
  return $std;
}
__PACKAGE__->meta->make_immutable;
1;
