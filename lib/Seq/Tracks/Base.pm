use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base;

our $VERSION = '0.001';

use Moose 2;
with 'Seq::Role::DBManager', 'Seq::Tracks::Definition', 'Seq::Role::Message';
use List::Util::XS; #qw/first/ doesn't work

has debug => (
  is => 'ro',
  isa => 'Int',
  lazy => 1,
  default => 1,
);

# should be shared between all types
# Since Seq::Tracks;:Base is extended by every Track, this is an ok place for it.
# Could also use state, and not re-initialize it for every instance
has genome_chrs => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    'allWantedChrs' => 'elements',
  },
  lazy_build => 1,
);

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

sub chrIsWanted {
  my ($self, $chr) = @_;

  #using internal methods, public API for public use (regarding wantedChrs)
  return List::Util::first { $_ eq $chr } @{$self->genome_chrs };
}

sub getData {
  my ($self, $href) = @_;

  my $data = $href->{$self->name};

  if(!defined $data) {
    $self->tee_logger('warn', "getAllFeaturesData passed hash ref that didn't
      contain data for the $self->name track");
    return;
  }

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
