#!/usr/bin/env perl

=head1 NAME

Statistics::StatisticsCalculator

=head1 SYNOPSIS
Calculates Transition:Transversion, SiteType:SiteTypePartner Ratios (default Silent:Replacement)
=head1 DESCRIPTION

=head1 AUTHOR
Alex Kotlar <akotlar@emory.ed>
based on David Cutler's transversion:transition calculator
=head1 Logic of Transition & Transversion counts:

If the genotype is an acceptable transition or transversion, it will be recorded always in the sample's summary statistics hash
Then, for each siteType and siteCode of that sample that is also in allowedTypesRef and allowedCodesRef respectively, the genotype
will be recorded.
So in some cases, the total number of transitiosn and transversions for a sample will not reflect the # of transitions and transversion summed from
siteTypes or siteCodes
====

=cut

package Seq::Statistics;

our $VERSION = '0.001';

# ABSTRACT: A class for sequence statistics
# VERSION

use 5.10.0;
use Moose;
use namespace::autoclean;

extends 'Seq::Statistics::Base';

use Seq::Statistics::Percentiles;
use DDP;

has statsKey => (
  is      => 'ro',
  isa     => 'Str',
  default => 'statistics',
);
has ratioKey => (
  is      => 'ro',
  isa     => 'Str',
  default => 'ratios',
);
has qcFailKey => (
  is      => 'ro',
  isa     => 'Str',
  default => 'qcFail',
);
has debug => (
  is      => 'ro',
  isa     => 'Int',
  default => 0,
);

with 'Seq::Statistics::Record';
with 'Seq::Statistics::Ratios';
with 'Seq::Role::Message';
with 'Seq::Statistics::Store';

#############################################################################
# Public Methods
#############################################################################

sub summarize {
  my $self = shift;
  my ( $percentilesHref, $destHref );

  $self->makeRatios;

  if ( $self->debug ) {
    say "Ratios:";
    p $self->ratiosHref;
  }

  if ( $self->hasNoRatios ) {
    #message
    return;
  }

  $destHref = $self->setStat( $self->statsKey, {} ); #init statKey at top of href;

  for my $kv ( $self->allRatiosKv ) {
    if ( !defined $kv->[1] ) { next; }               #not certain this needed

    $percentilesHref = Seq::Statistics::Percentiles->new(
      ratioName => $kv->[0],
      ratios    => $kv->[1],
      qcFailKey => $self->qcFailKey,
      target    => $destHref,
    );

    if ( !$percentilesHref->hasPercentiles ) { next; }

    $percentilesHref->storeAndQc;

    if ( $self->debug ) {
      say "after qc, stats record has";
      p $self->statsRecord;
    }

    $self->log( 'info', 'Finished calculating statistics' );
  }
}
__PACKAGE__->meta->make_immutable;
1;

=head1 COPYRIGHT

Copyright (c) 2014 Alex Kotlar (<alex.kotlar@emory.edu>). All rights
reserved.

=head1 LICENSE
