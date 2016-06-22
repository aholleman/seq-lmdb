use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Site::SiteTypeMap;

use Moose 2;
use Moose::Util::TypeConstraints;
use DDP;
# define allowable types
# not at the moment exposing these publicly, no real need
state $codingSite = 'Coding';
has codingSiteType => (is=> 'ro', lazy => 1, init_arg => undef, default => sub{$codingSite} );
state $fivePrimeSite = '5UTR';
has fivePrimeSiteType => (is=> 'ro', lazy => 1, init_arg => undef, default => sub{$fivePrimeSite} );
state $threePrimeSite = '3UTR';
has threePrimeSiteType => (is=> 'ro', lazy => 1, init_arg => undef, default => sub{$threePrimeSite} );
state $spliceAcSite = 'SpliceAcceptor';
has spliceAcSiteType => (is=> 'ro', lazy => 1, init_arg => undef, default => sub{$spliceAcSite} );
state $spliceDonSite = 'SpliceDonor';
has spliceDonSiteType => (is=> 'ro', lazy => 1, init_arg => undef, default => sub{$spliceDonSite} );
state $ncRNAsite = 'NonCodingRNA';
has ncRNAsiteType => (is=> 'ro', lazy => 1, init_arg => undef, default => sub{$ncRNAsite} );
state $intronicSite = 'Intronic';
has intronicSiteType => (is=> 'ro', lazy => 1, init_arg => undef, default => sub{$intronicSite} );

# #Coding type always first; order of interest
state $siteTypes = [$codingSite, $fivePrimeSite, $threePrimeSite,
  $spliceAcSite, $spliceDonSite, $ncRNAsite, $intronicSite];

# #public
has siteTypes => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    allSiteTypes => 'elements',
    getSiteType => 'get',
  },
  lazy => 1,
  init_arg => undef,
  default => sub{$siteTypes},
);

has nonCodingBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 1,
);

has codingBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 2,
);

has fivePrimeBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 3,
);

has threePrimeBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 4,
);

has spliceAcBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 5,
);

has spliceDonBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 6,
);

has intronicBase => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  lazy => 1,
  default => 7,
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
  my $self = shift;

  state $mapHref = {
    $self->nonCodingBase => $ncRNAsite,
    $self->codingBase => $codingSite,
    $self->fivePrimeBase => $fivePrimeSite,
    $self->threePrimeBase => $threePrimeSite,
    $self->spliceAcBase => $spliceAcSite,
    $self->spliceDonBase => $spliceDonSite,
    $self->intronicBase => $intronicSite,
  };

  return $mapHref;
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
  my $self = shift;

  state $inverse =  { map { $self->siteTypeMap->{$_} => $_ } keys %{$self->siteTypeMap} };

  return $inverse;
}

has exonicSites => (
  is => 'ro',
  init_arg => undef,
  lazy => 1,
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    isExonicSite => 'exists',
  },
  default => sub {
    return { map { $_ => 1 } ($codingSite, $ncRNAsite, $fivePrimeSite, $threePrimeSite) };
  },
);

__PACKAGE__->meta->make_immutable;
1;
