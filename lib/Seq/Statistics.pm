use 5.10.0;
use strict;
use warnings;

package Seq::Statistics;
use Moose 2;

# use Seq::Tracks;
with 'Seq::Role::ConfigFromFile';

my $siteHandler = Seq::Tracks::Gene::Site->new();

# From YAML config, the gene track and snp track whose features we take ratios of
has gene_track_name => (is => 'ro', isa => 'Str', required => 1);
has snp_track_name => (is => 'ro', isa => 'Str', required => 1);

# We need to konw where the heterozygotes homozygotes, and minor alleles are located
has heterozygoteIdsKey =>  (is => 'ro', isa => 'Str', required => 1);
has homozygoteIdsKey =>  (is => 'ro', isa => 'Str', required => 1);
has minorAllelesKey => (is => 'ro', isa => 'Str', required => 1);

my %transitionGenos = (AG => 1, GA => 1, CT => 1, TC => 1);

my $siteTypeKey = $siteHandler->siteTypeKey;

my $trKey = 'Transitions';
my $tvKey = 'Transversions';
my $totalKey = 'Total';
my $dbSnpKey = 'DbSNP';
my $ratioKey = 'ratio';

# cache the names, avoid lookup time
my ($refTrack, $geneTrackName, $snpTrackName, $hetKey, $homeKey, $alleleKey);
sub BUILD{
  my ($self) = @_;

  $hetKey = $self->heterozygoteIdsKey;
  $homKey = $self->homozygoteIdsKey;
  $allelesKey = $self->minorAllelesKey;

  my $tracks = Seq::Tracks->new();
  $refTrack = $tracks->singletonTracks->getRefTrackGetter;

  $geneTrackName = $self->gene_track_name;
  $snpTrackName = $slef->snpTrackName;
}

# Take data for a single position and generate trTv statistics
sub countTransitionsAndTransversions {
  my ($self, @outputFields ) = @_;

  my (%transitions, %transversions);

  foreach (@outputFields) {
    my @sampleIds = ( @{ $_->{$hetIdKey} },  @{ $_->{$homIdKey} } );

    my $isTrans = 0;

    my $reference = $_->{$refTrack->name};
    my $minorAlleles = $_->{$alleleKey};

    # We don't include multi-allelic sites for now
    if(ref $minorAlleles) {
      next;
    }

    # The alleles field is always ACTG, and doesn't include the reference
    if( $transitionGenos{"$minorAlleles$reference"} ){
      $isTrans = 1;
    }

    my %notUniqueSiteType;
    my $allSites = $output->{$geneTrackName}{$siteTypeKey};
    for my $siteType (ref $allSites ? @{$allSites} : $allSites) {
      if($notUniqueSiteType{$siteType} ) {
        next;
      }

      $notUniqueSiteType{$siteType} = 1;

      if(!defined $transitions{$totalKey}{$siteType}) {
        $transitions{$totalKey}{$siteType} = 0;
        $transversions{$totalKey}{$siteType} = 0;
      }

      if($isTrans) { $transitions{$totalKey}{$siteType}++; }
      else { $transversions{$totalKey}{$siteType}++; }

      #has RS
      my $hasRs;
      if( $output->{$snpTrackName}{name} ) {
        $hasRs = 1;

        if(!defined $transitions{$totalKey}{"$siteType$dbSnpKey"}) {
          $transitions{$totalKey}{"$siteType$dbSnpKey"} = 0;
          $transversions{$totalKey}{"$siteType$dbSnpKey"} = 0;
        }

        if($isTrans) { $transitions{$totalKey}{"$siteType$dbSnpKey"}++; }
        else { $transversions{$totalKey}{"$siteType$dbSnpKey"}++; }
      }

      SAMPLE_LOOP: for my $sampleId (@sampleIds) {
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
          next SAMPLE_LOOP;
        }

        $transversions{$sampleId}{$siteType}++;
        if($hasRs) { $transversions{$sampleId}{"$siteType$dbSnpKey"}++; }
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
      for my $siteType (keys %{ $addHref->{$trOrTvKey}{$sampleId} } ) {
        if( !defined $allHref->{$trOrTvKey}{$sampleId}{$siteType} ) {
          $allHref->{$trOrTvKey}{$sampleId}{$siteType} =
            $addHref->{$trOrTvKey}{$sampleId}{$siteType};
          next;
        }

        $allHref->{$trOrTvKey}{$sampleId}{$siteType} +=
          $addHref->{$trOrTvKey}{$sampleId}{$siteType};
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

  my $totalTr = 0;
  my $totalTv = 0;
  for my $sampleId (keys %$transitions) {
    for my $siteType (keys %{ $transitions->{$sampleId} } ) {
      $totalTr += $transitions->{$sampleId}{$siteType};
      $totalTv += $transversions->{$sampleId}{$siteType};

      if($transversions->{$sampleId}{$siteType} > 0) {
        $ratios{$sampleId}{"$siteType $trKey:$tvKey $ratioKey"} =
          $transitions->{$sampleId}{$siteType} / $transversions->{$sampleId}{$siteType};
      }
      
    }
  }

  if($totalTv > 0) {
    $ratios{$totalKey}{"$trKey:$tvKey $ratioKey"} = $totalTr/$totalTv;
  }

}

__PACKAGE__->meta->make_immutable;
1;
