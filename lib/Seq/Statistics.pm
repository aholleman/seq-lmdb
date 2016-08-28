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
my $transitionsKey = 'transitions';
my $transversionsKey = 'transversions';
my $trTvRatioKey = 'transitions:transversions ratio';
my $totalKey = 'total';
my $dbSnpKey = 'dbSNP';

# cache the names, avoid lookup time
my ($refTrack, $geneTrack, $geneTrackName, $snpTrackName, $hetKey, $homKey, $alleleKey);
sub BUILD{
  my ($self) = @_;

  $hetKey = $self->heterozygoteIdsKey;
  $homKey = $self->homozygoteIdsKey;
  $alleleKey = $self->minorAllelesKey;

  my $tracks = Seq::Tracks->new({gettersOnly => 1});
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
      next OUTPUT_LOOP;
    }
    
    my $isTrans = 0;
    my $hasRs; 

    my $reference = $_->{$refTrack->name};

    if(!$reference) {
      say "reference is";
      p $reference;
      p $_;
      p $refTrack->name;
    }
    

    my $minorAlleles = $_->{$alleleKey};

    # We don't include multi-allelic sites for now
    if(ref $minorAlleles || ! $minorAlleles =~ /ACTG/) {
      next OUTPUT_LOOP;
    }

    if(!defined $transitions{$totalKey}{$totalKey}) {
      $transitions{$totalKey}{$totalKey} = 0;
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
    if( defined $_->{$snpTrackName}{name} ) {
      $hasRs = 1;
    }

    if($hasRs) {
      if(!defined $transitions{$totalKey}{$dbSnpKey}) {
        $transitions{$totalKey}{$dbSnpKey} = 0;
        $transversions{$totalKey}{$dbSnpKey} = 0;
      }

      if($isTrans) { $transitions{$totalKey}{$dbSnpKey}++; } 
      else { $transversions{$totalKey}{$dbSnpKey}++; }
    }

    OUTER_SAMPLE_LOOP: for my $sampleId (ref $sampleIds ? @$sampleIds : $sampleIds) {
      if(!defined $transitions{$sampleId}{$totalKey}) {
        $transitions{$sampleId}{$totalKey} = 0;
        $transversions{$sampleId}{$totalKey} = 0;
      }

      if($isTrans) { $transitions{$sampleId}{$totalKey}++; }
      else { $transversions{$sampleId}{$totalKey}++; }

      if($hasRs) { 
        if(!defined $transitions{$sampleId}{$dbSnpKey}) {
          $transitions{$sampleId}{$dbSnpKey} = 0;
          $transversions{$sampleId}{$dbSnpKey} = 0;
        }

        if($isTrans) { $transitions{$sampleId}{$dbSnpKey}++; } 
        else { $transversions{$sampleId}{$dbSnpKey}++; }
      }
    }

    # For every unique site type, count whether this position is a transition or transversion
    my %notUniqueSiteType;
    my $allSites = $_->{$geneTrackName}{$siteTypeKey};

    SITE_TYPE_LOOP: for my $siteType (ref $allSites ? @{$allSites} : $allSites) {
      # siteTypes probably won't be undefined, but API could change
      # undefined values would then be used to keep output order in flattened table format
      if(!defined $siteType) { next SITE_TYPE_LOOP; }

      if(defined $notUniqueSiteType{$siteType} ) { next SITE_TYPE_LOOP; }

      $notUniqueSiteType{$siteType} = 1;

      if(!defined $transitions{$totalKey}{$siteType}) {
        $transitions{$totalKey}{$siteType} = 0;
        $transversions{$totalKey}{$siteType} = 0;
      }

      if($isTrans) { $transitions{$totalKey}{$siteType}++; }
      else { $transversions{$totalKey}{$siteType}++; }

      if($hasRs) {
        if(!defined $transitions{$totalKey}{"$siteType\_$dbSnpKey"}) {
          $transitions{$totalKey}{"$siteType\_$dbSnpKey"} = 0;
          $transversions{$totalKey}{"$siteType\_$dbSnpKey"} = 0;
        }

        if($isTrans) { $transitions{$totalKey}{"$siteType\_$dbSnpKey"}++; }
        else { $transversions{$totalKey}{"$siteType\_$dbSnpKey"}++; }
      }

      SAMPLE_LOOP: for my $sampleId (ref $sampleIds ? @$sampleIds : $sampleIds) {
        if(!defined $transitions{$sampleId}{$siteType}) {
          $transitions{$sampleId}{$siteType} = 0;
          $transversions{$sampleId}{$siteType} = 0;
        }

        if($hasRs && !defined $transitions{$sampleId}{"$siteType\_$dbSnpKey"}) {
          $transitions{$sampleId}{"$siteType\_$dbSnpKey"} = 0;
          $transversions{$sampleId}{"$siteType\_$dbSnpKey"} = 0;
        }

        if($isTrans) {
          $transitions{$sampleId}{$siteType}++;
          if($hasRs) { $transitions{$sampleId}{"$siteType\_$dbSnpKey"}++; }
        } else {
          $transversions{$sampleId}{$siteType}++;
          if($hasRs) { $transversions{$sampleId}{"$siteType\_$dbSnpKey"}++; }
        }
      }
    }

    # Likewise, for every unique txEffect type, count whether this position is a transition or transversion
    if(!defined $_->{$geneTrackName}{$geneTrack->txEffectsKey} ) {
      next OUTPUT_LOOP;
    }

    my %notUniqueTxEffectType;
    my $allTxEffects = $_->{$geneTrackName}{$geneTrack->txEffectsKey};

    #TODO: Figure out if it would be better for Seq::Tracks::Gene to output 
    #single level array when there is only a single allele
    #Currently Seq::Tracks::Gene outputs a 2 level array for 1 allele
    ALL_TX_EFFECTS_LOOP: foreach (@$allTxEffects) {
      # Non coding sites
      if(!defined $_) { next; }

      TX_EFFECT_LOOP: for my $txEffect (ref $_ ? @{$_} : $_) {
        # We may set some txEffects as undef in the output to conserve space
        # While retaining output (flattened in table) order
        # Occurs in case of multiple transcripts
        if(!defined $txEffect) { next TX_EFFECT_LOOP; }

        if(defined $notUniqueTxEffectType{$txEffect} ) { next TX_EFFECT_LOOP; }

        $notUniqueTxEffectType{$txEffect} = 1;

        if(!defined $transitions{$totalKey}{$txEffect}) {
          $transitions{$totalKey}{$txEffect} = 0;
          $transversions{$totalKey}{$txEffect} = 0;
        }

        if($isTrans) { $transitions{$totalKey}{$txEffect}++; }
        else { $transversions{$totalKey}{$txEffect}++; }

        if( $hasRs ) {
          if(!defined $transitions{$totalKey}{"$txEffect\_$dbSnpKey"}) {
            $transitions{$totalKey}{"$txEffect\_$dbSnpKey"} = 0;
            $transversions{$totalKey}{"$txEffect\_$dbSnpKey"} = 0;
          }

          if($isTrans) { $transitions{$totalKey}{"$txEffect\_$dbSnpKey"}++; }
          else { $transversions{$totalKey}{"$txEffect\_$dbSnpKey"}++; }
        }

        SAMPLE_LOOP: for my $sampleId (ref $sampleIds ? @$sampleIds : $sampleIds) {
          if(!defined $transitions{$sampleId}{$txEffect}) {
            $transitions{$sampleId}{$txEffect} = 0;
            $transversions{$sampleId}{$txEffect} = 0;
          }

          if($hasRs && !defined $transitions{$sampleId}{"$txEffect\_$dbSnpKey"}) {
            $transitions{$sampleId}{"$txEffect\_$dbSnpKey"} = 0;
            $transversions{$sampleId}{"$txEffect\_$dbSnpKey"} = 0;
          }

          if($isTrans) {
            $transitions{$sampleId}{$txEffect}++;
            if($hasRs) { $transitions{$sampleId}{"$txEffect\_$dbSnpKey"}++; }
          } else {
            $transversions{$sampleId}{$txEffect}++;
            if($hasRs) { $transversions{$sampleId}{"$txEffect\_$dbSnpKey"}++; }
          }
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
  for my $trOrTvKey ($transitionsKey, $transversionsKey) {
    # total or a sampleId
    for my $sampleId (keys %{ $addHref->{$trOrTvKey} } ) {
      # total or site types or txEffect or intersectio of site/txEffect with dbSnpKey
      INNER: for my $siteType (keys %{ $addHref->{$trOrTvKey}{$sampleId} } ) {
        if( !defined $allHref->{$trOrTvKey}{$sampleId}{$siteType} ) {
          $allHref->{$trOrTvKey}{$sampleId}{$siteType} = $addHref->{$trOrTvKey}{$sampleId}{$siteType};
          next INNER;
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

  # Used for quality control calculations of overall tr:tv ratio being within 3SD
  my @allSampleRatios;

  # This function suggests output order as well, since it owns the output fields
  my @order;

  # All "sampleId" (including total key) have the same siteTypes
  # this is guaranteed in accumulateValues
  my %siteTypesOrTxEffectsSeen;

  # the transitions key and transversions key should posesses the same sample list
  # we'll know if not in the output, and that would be a programming error
  my @allSamples = keys %$transitions;

  ####################### First accumulate all defined values ##################
  # total or sampleId
  for my $sampleId (@allSamples) {
    # site type
    for my $siteType (keys %{$transitions->{$sampleId} } ) {
      # We'll store the raw counts as well as ratios;
      #this will include $totalKey $tansitionsKey and $totalKey $transversionsKey
      $ratios{$sampleId}{"$siteType $transitionsKey"} = $transitions->{$sampleId}{$siteType};
      $ratios{$sampleId}{"$siteType $transversionsKey"} = $transversions->{$sampleId}{$siteType};

      if($transversions->{$sampleId}{$siteType} > 0) {
        $ratios{$sampleId}{"$siteType $trTvRatioKey"} = sprintf "%0.2f",
          $transitions->{$sampleId}{$siteType} / $transversions->{$sampleId}{$siteType};
      } else {
        # TODO: use Seq::Output 's undefined value attribute
        $ratios{$sampleId}{"$siteType $trTvRatioKey"} = "NA";
      }

      if(!defined $siteTypesOrTxEffectsSeen{$siteType} ) {
        $siteTypesOrTxEffectsSeen{$siteType} = 1;
      }
    }

    # @allSampleRatios is used to determine 3SD quality control range
    push @allSampleRatios, $ratios{$sampleId}{"$totalKey $trTvRatioKey"};
  }

  if(!@allSampleRatios) {
    return undef;
  }

  ####################### Now accumulate all undefined values ##################

  my @allSiteOrTxEffectTypesSeen = keys %siteTypesOrTxEffectsSeen;

  #Guarantee that all samples have the same ratios and raw counts
  for my $sampleId (@allSamples) {
    # site type
    for my $siteType (@allSiteOrTxEffectTypesSeen) {
      if(!defined $transitions->{$sampleId}{$siteType} ) {
        $ratios{$sampleId}{"$siteType $transitionsKey"} = 0;
        $ratios{$sampleId}{"$siteType $transversionsKey"} = 0;
        $ratios{$sampleId}{"$siteType $trTvRatioKey"} = "NA";
      }
    }
  }

  ####################### Suggest output order to consumers ####################

  foreach ( @{Sort::XS::quick_sort_str(\@allSiteOrTxEffectTypesSeen) } ) {
    #total transtitions, total transversions, & total transitions:transversions goes last
    if ($_ ne $totalKey) {
      push @order, "$_ $transitionsKey", "$_ $transversionsKey", "$_ $trTvRatioKey";
    }
  }

  # These items should be output last
  push @order, "$totalKey $transitionsKey";
  push @order, "$totalKey $transversionsKey";
  push @order, "$totalKey $trTvRatioKey";

  my $mean = $self->_mean(\@allSampleRatios);
  my $standardDev = $self->_stDev(\@allSampleRatios, $mean);

  $qualityControl{stats}{"$transitionsKey:$transversionsKey mean"} = $mean;
  $qualityControl{stats}{"$transitionsKey:$transversionsKey standard deviation"} = $standardDev;

  if(defined $standardDev) {
    my $threeSd = 3*$standardDev;

    for my $sampleId (keys %sampleTotalTransitions) {
      if(abs($ratios{$sampleId}{$trTvRatioKey} - $mean) > $threeSd) {
        $qualityControl{fail}{$sampleId} = ">3SD";
      }
    }
  }
  

  return {ratios => \%ratios, ratiosOutputOrder => \@order, qc => \%qualityControl};
}

sub printStatistics {
  my ($self, $statsHref, $outputFilePath) = @_;

  if(!$statsHref || !%$statsHref) {
    return;
  }

  my $ratiosHref = $statsHref->{ratios};
  my @outputOrder = @{ $statsHref->{ratiosOutputOrder} };
  my $qcHref = $statsHref->{qc};

  my $ratiosExt = '.stats.ratios.tab';
  my $qcExt = '.stats.qc.tab';

  ######################## Print ratios ############################

  my $fh = $self->get_write_fh($outputFilePath . $ratiosExt);

  # The first cell is blank or call it Sample
  say $fh join("\t", "Sample", @outputOrder);

  for my $sampleId ( @{  Sort::XS::quick_sort_str( [keys %$ratiosHref] ) } ) {
    say $fh "$sampleId\t" . join("\t", map { $ratiosHref->{$sampleId}{$_} } @outputOrder);
  }

  close $fh;

  ###################### Print Quality Contorl Information #####################
  $fh = $self->get_write_fh($outputFilePath . $qcExt);

  foreach ( keys %{$qcHref->{stats} } ) {
    say $fh "$_\t$qcHref->{stats}{$_}";
  }

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
sub _mean {
  my($self, $data) = @_;
  if (!@$data) {
    return $self->log('warn', "Data required in _mean");
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

  if(!defined $average) {
    return undef;
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
