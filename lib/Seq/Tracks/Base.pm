use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base;

our $VERSION = '0.001';

use Moose 2;
with 'Seq::Role::DBManager', 'Seq::Tracks::Definition', 'Seq::Role::Message';

#only required for building;
has features => (
  is => 'ro',
  isa => 'ArrayRef[Str|HashRef]',
  lazy => 1,
  traits   => ['Array'],
  default  => sub{[]},
  handles  => { allFeatures => 'elements', noFeatures => 'is_empty' },
);

has name => ( is => 'ro', isa => 'Str', required => 1);

has type => ( is => 'ro', isa => 'Str', required => 1);

sub getAllFeaturesData {
  my ($self, $href) = @_;

  if(!defined $href->{$self->name}
  || !defined $href->{$self->name}{$self->dataKey} ) {
    $self->tee_logger('warn', "getAllFeaturesData passed hash ref that didn't
      contain data for the $self->name track");
    return;
  }

  my $data = $href->{$self->name}{$self->dataKey};
  
  if($self->noFeatures) {
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

#

#all the data we wish to include for this type
#expects { feature1 : {stuff} | stuff , feature2 : {stuff} | stuff }
# has data => (
#   is => 'rw',
#   isa => 'HashRef',
#   lazy => 1,
#   traits => ['Hash'],
#   handles => {
#     'getFeatureData' => 'get', #accepts a featureName
#     'setFeatureData' => 'set', #accepts a featureName
#   },
#   default => {},
# );


__PACKAGE__->meta->make_immutable;

1;
