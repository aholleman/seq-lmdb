use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Get;
# Synopsis: For fetching data
# TODO: make this a role?
our $VERSION = '0.001';

use Moose 2;
extends 'Seq::Tracks::Base';


#label => featureNameAsItAppearsInInputFile
has _invertedFeatures => (
  is => 'ro',
  isa => 'HashRef[Str]',
  lazy => 1,
  traits => ['Hash'],
  handles  => {
    getFeatureName => 'get',
  },
  _builder => '_buildInvertedFeatures',
);

sub _buildInvertedFeatures {
  my $self = shift;

  if($self->noFeatures) {
    return {};
  }
  
  my %invertedIdx;
  for my $pair ($self->allFeatureNamesDbNames) {
    my $name = $pair->[0];
    my $storedAs = $pair->[1]; #what it's stored in the database as

    $invertedIdx{$storedAs} = $name;
  }
  return \%invertedIdx;
}

sub getData {
  my ($self, $href) = @_;

  my $data = $href->{$self->name};

  if(!defined $data) {
    $self->tee_logger('warn', "getAllFeaturesData passed hash ref that didn't
      contain data for the $self->name track");
    return;
  }

  if(!$self->features) {
    return $data;
  }

  my %out;
  if(ref $data ne 'HASH') {
    $self->tee_logger('warn', "Expected data to be HASH reference, got " 
      . ref $data);
  }
  #may be simpler in a map
  #Goal here is to  return only what the user cares about
  for my $feature ($self->allFeatures) {
    my $val = $data->($feature);
    if ($val) {
      $out{$feature} = $val;
    }
  }
  return \%out;
}

__PACKAGE__->meta->make_immutable;

1;
