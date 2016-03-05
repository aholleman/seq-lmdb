use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Definition;

our $VERSION = '0.001';

# ABSTRACT: A base class for track classes
# VERSION

use Moose::Role;
use Moose::Util::TypeConstraints; 
use namespace::autoclean;

=property @public @required {Str} name

  The track name. This is defined directly in the input config file.

  @example:
  =for :list
  * gene
  * snp

=cut

state $typeKey = 'type';
has typeKey => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$typeKey});


state $dataKey = 'data';
has dataKey => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$dataKey});

# I've coupled this to gene
# state $ngeneType = 'ngene';
# has ngeneType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$ngeneType});

state $refType = 'reference';
has refType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$refType});

state $geneType = 'gene';
has geneType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$geneType});

state $scoreType = 'score';
has scoreType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$scoreType});

state $sparseType = 'sparse';
has sparseType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$sparseType});

state $snpType = 'snp';
has snpType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$snpType});

state $regionType = 'region';
has regionType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$regionType});

enum TrackType => [$refType, $geneType, 
  $scoreType, $sparseType, $snpType, $regionType];

#This may not be the smartest way to organize these mappings
#Maybe they should go in Seq::Tracks and Seq::Tracks::Build
state $trackMap = {
  $refType => 'Seq::Tracks::ReferenceTrack',
  $geneType => 'Seq::Tracks::GeneTrack',
  $scoreType => 'Seq::Tracks::ScoreTrack',
  $sparseType => 'Seq::Tracks::SparseTrack',
  $snpType => 'Seq::Tracks::SnpTrack',
  $regionType => 'Seq::Tracks::RegionTrack',
};

has trackMap => (
  is => 'ro',
  isa => 'HashRef',
  lazy => 1,
  handles => {
    getTrack => 'get',
  },
  init_arg => undef,
  default => sub {$trackMap},
);

state $trackBuildMap = {
  $refType => 'Seq::Tracks::ReferenceTrack::Build',
  $geneType => 'Seq::Tracks::GeneTrack::Build',
  $scoreType => 'Seq::Tracks::ScoreTrack::Build',
  $sparseType => 'Seq::Tracks::SparseTrack::Build',
  $snpType => 'Seq::Tracks::SnpTrack::Build',
  $regionType => 'Seq::Tracks::RegionTrack::Build',
};

has trackBuildMap => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getBuilder => 'get',
  },
  lazy => 1,
  init_arg => undef,
  default => sub {$trackBuildMap}
);

no Moose::Role;
1;