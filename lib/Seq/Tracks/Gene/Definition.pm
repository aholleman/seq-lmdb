use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Definition;
use Moose::Role 2;
#Defines a few keys common to the build and get functions of Tracks::Gene

has siteFeatureName => (is => 'ro', init_arg => undef, lazy => 1, default => 'site');
has geneTrackRegionDatabaseTXerrorName => (is => 'ro', init_arg => undef, lazy => 1, default => 'txError');

no Moose::Role;
1;