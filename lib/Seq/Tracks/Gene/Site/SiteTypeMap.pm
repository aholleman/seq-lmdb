use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Site::SiteTypeMap;

use Moose::Role 2;
with 'Seq::Site::Definition';

has nonCodingBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 0,
);

has codingBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 1,
);

has fivePrimeBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 2,
);

has threePrimeBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 3,
);

has spliceAcBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 4,
);

has spliceDonBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 5,
);

#TODO: should constrain values to GeneSiteType
has siteTypeMap => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getSiteTypeFromNum => 'get',
  },
  lazy => 1,
  init_arg => undef,
  builder => '_buildSiteTypeMap',
);

sub _buildSiteTypeMap {
  state $mapHref;
  if($mapHref) {
    return $mapHref;
  }

  my $self = shift;

  return {
    $self->nonCodingBase => $self->ncRNAsiteType,
    $self->codingBase => $self->codingSiteType,
    $self->fivePrimeBase => $self->fivePrimeSiteType,
    $self->threePrimeBase => $self->threePrimeSiteType,
    $self->spliceAcBase => $self->spliceAcSiteType,
    $self->spliceDonBase => $self->spliceDonSiteType,
  };
}

#takes a GeneSite value and returns a number, matching the _siteTypeMap key
has siteTypeMapInverse => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getSiteTypeNum => 'get',
  },
  lazy => 1,
  init_arg => undef,
  builder => '_buildSiteTypeMapInverse',
);

sub _buildSiteTypeMapInverse {
  state $mapInverse;
  if($mapInverse) {
    return $mapInverse;
  }

  my $self = shift;

  my $href;
  for my $num (keys %{$self->siteTypeMap} ) {
    $href->{ $self->siteTypeMap->{$num} } = $num;
  }

  return $href;
  # return { 
  #   $self->ncRNAsiteType => 0,
  #   $self->codingSiteType => 1,
  #   $self->threePrimeSiteType => 2,
  #   $self->fivePrimeSiteType => 3,
  #   $self->spliceAcSite => 4,
  #   $self->spliceDoSite => 5,
  # }
}

no Moose::Role;
1;
