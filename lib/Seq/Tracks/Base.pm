use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base;
#Every track class extends this. The attributes detailed within are used
#regardless of whether we're building or annotating
#and nothing else ends up here (for instance, required_fields goes to Tracks::Build) 

our $VERSION = '0.001';

use Moose 2;
with 'Seq::Role::DBManager', 'Seq::Tracks::Definition', 'Seq::Role::Message';
use List::Util::XS; #qw/first/ doesn't work
use DDP;

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


#the "noFeatures", "noDataTypes" is really ugly; unfortunately
#moose doesn't allow traits + Maybe or Undef types
#could defined data types here,
#but then getting feature names is more awkward
#ArrayRef[Str | Maybe[HashRef[DataType] ] ]
has features => (
  is => 'ro',
  isa => 'HashRef[Str]',
  lazy => 1,
  handles  => { 
    allFeatures => 'keys',
    getFeatureLabel => 'get',
    allFeatureNamesLabels => 'kv',
    noFeatures  => 'is_empty',
  },
);

#users can specify a data type, if found it must by one of
#DataType, defined in Seq::Tracks::Definition
#this is not meant to be set in YAML
#however, if I use init_arg undef, the my around BUILDARGS won't be able to set it
#Advantage of storing here instead of inside features hash, is we can coerce
#more Moosey
has _featureDataTypes => (
  is => 'ro',
  isa => 'HashRef[DataType]',
  lazy => 1,
  traits   => ['Hash'],
  default  => sub{{}},
  handles  => { 
    getFeatureType => 'get', 
    noFeatureTypes => 'is_empty',
  },
);

#The mapping of featureDataTypes needs to happne here, becaues if
#the feature is - name :type , that's a hash ref, and features expects 
#ArrayRef[Str].
#we could explicitly check for whether a hash was passed
#but not doing so just means the program will crash and burn if they don't
#note that by not shifting we're implying that the user is submitting an href
#if they don't required attributes won't be found
#so the messages won't be any uglier
around BUILDARGS => sub {
  my ($orig, $class, $data) = @_;

  if(!$data->{features} ) {
    return $class->$orig($data);
  }
  
  #we convert the features into a hashRef
  # {
  #  featureNameAsAppearsInHeader => <Str> (what we store it as)
  #}
  my %featureLabels;
  for my $feature (@{$data->{features} } ) {
    if (ref $feature eq 'HASH') {
      my ($name, $type) = %$feature; #Thomas Wingo method

      #users can explicilty tell us what they want
      #-features:
        # blah:
          # - type : int
          # - store : b
      if(ref $type eq 'HASH') {
        if($type->{store}) {
          $featureLabels{$name} = $type->{store};
        }
        if( $type->{type} ) {
          $data->{_featureDataTypes}{$name} = $type->{type};
        }
        next;
      } else {
        $data->{_featureDataTypes}{$name} = $type;
      }
      
      $featureLabels{$name} = $name;
    }
  }
  $data->{features} = \%featureLabels;

  say "data is";
  p $data;
  exit;
  $class->$orig($data);
};

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
