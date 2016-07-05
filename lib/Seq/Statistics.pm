use 5.10.0;
use strict;
use warnings;

package Seq::Statistics;
use Moose 2;
use Seq::Genotypes;
use List::MoreUtils qw/uniq/;

use Seq::Tracks;
with 'Seq::Role::ConfigFromFile';

my $siteHandler = Seq::Tracks::Gene::Site->new();
my $genotypes = Seq::Genotypes->new();

has gene_track_name => (is => 'ro', isa => 'str', required => 1);
has snp_track_name => (is => 'ro', isa => 'str', required => 1);

my $transitions = { AG => 1, GA => 1, CT => 1, TC => 1};

my ($hetIdKey, $homIdKey, $alleleKey);

my $siteTypeKey = $siteHandler->siteTypeKey;

my $trKey = 'Transitions';
my $tvKey = 'Transversions';
my $totalKey = 'Total';
my $isRsKey = 'in_db_snp';

my ($refTrack, $geneTrackName, $snpTrackName)
sub BUILD{
  my ($self, $heterozygoteIdKey, $homozygoteIdKey, $minorAllelKey) = @_;

  $hetIdKey = $heterozygoteIdKey;
  $homIdKey = $homozygoteIdKey;
  $alleleKey = $minorAlleleKey;

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
    if( $genotypes->isTrans("$minorAlleles$reference" ){
      $isTrans = 1;
    }

    my %notUniqueSiteType;
    my $allSites = $output->{$geneTrackName}{$siteTypeKey};
    for my $siteType (ref $allSites ? @{$allSites} : $allSites) {
      if($notUniqueSiteType{$siteType} ) {
        next;
      }

      $notUniqueSiteType{$siteType} = 1;

      $transversions{$siteType} = $transversions{$siteType} || 0;
      $transitions{$siteTYpe} = $transitions{$siteType} || 0;

      if($isTrans) { $transitions{total}{$siteType}++; }
      else { $transversions{total}{$siteType}++; }

      #has RS
      my $hasRs;
      if( $output->{$geneTrackName}{name} ) {
        $hasRs = 1;
        if($isTrans == 0) { $transitions{total}{"$siteType_$isRsKey"}++; }
        else { $transversions{total}{"$siteType_$isRsKey"}++; }
      }

      SAMPLE_LOOP: for my $sampleId (@sampleIds) {
        if($isTrans) {
          $transitions{$sampleId}{$siteType}++;
          if($hasRs) { $transitions{$sampleId}{"$siteType_$isRsKey"}++; }
          next SAMPLE_LOOP;
        }

        $transversions{$sampleId}{$siteType}++;
        if($hasRs) { $transversions{$sampleId}{"$siteType_$isRsKey"}++; }
      }
    }

  }
}

# Seperate processes/threads may build up results, we may want to combine the totals
sub combine {
  my ($self, $collectionHref, $addHref) = @_;

  for my $parent (keys %$collectionHref) {
    if(!ref $collectionHref->{$parent}) {
      if( && $addHref->{$parent}) {
        $collectionHref->{$parent} += $addHref->{$parent};
      }
      next;
    }
    
    if(!ref $collectionHref->{$parent}) {

    }

    goto &
  }
}

sub makeRatios {
  my ($self, $transitions, $transversion) = @_;

  for my $
}

sub 
__PACKAGE__->meta->make_immutable;
1;
