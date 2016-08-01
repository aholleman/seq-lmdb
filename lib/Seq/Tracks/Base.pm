use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base;
#Every track class extends this. The attributes detailed within are used
#regardless of whether we're building or annotating
#and nothing else ends up here (for instance, required_fields goes to Tracks::Build) 

our $VERSION = '0.001';

use Mouse 2;
use MouseX::NativeTraits;

use DDP;
use List::MoreUtils qw/first_index/;

use Seq::Tracks::Base::MapTrackNames;
use Seq::Tracks::Base::MapFieldNames;

# automatically imports TrackType
use Seq::Tracks::Base::Types;

with 'Seq::Role::Message';

################# Public Exports ##########################
# Not lazy because every track will use this 100%, and rest are trivial values
# Not worth complexity of Maybe[Type], default => undef,
has dbName => ( is => 'ro', init_arg => undef, writer => '_setDbName');

# Some tracks may have a nearest property; these are stored as their own track, but
# conceptually are a sub-track, 
has nearesTrackName => ( is => 'ro', isa => 'Str', init_arg => undef, default => 'nearest');

has nearestDbName => ( is => 'ro', isa => 'Str', init_arg => undef, writer => '_setNearestDbName');

has joinTrackFeatures => (is => 'ro', isa => 'ArrayRef', init_arg => undef, writer => '_setJoinTrackFeatures');

has joinTrackName => (is => 'ro', isa => 'Str', init_arg => undef, writer => '_setJoinTrackName');

###################### Required Arguments ############################
# the track name
has name => ( is => 'ro', isa => 'Str', required => 1);

has type => ( is => 'ro', isa => 'TrackType', required => 1);

#anything with an underscore comes from the config format
#anything config keys that can be set in YAML but that only need to be used
#during building should be defined here
has chromosomes => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    allWantedChrs => 'keys',
    chrIsWanted => 'defined', #hash over array because unwieldy firstidx
  },
  required => 1,
);

has fieldNames => (is => 'ro', init_arg => undef, default => sub {
  my $self = shift;
  return Seq::Tracks::Base::MapFieldNames->new({name => $self->name, debug => $self->debug});
}, handles => ['getFieldDbName', 'getFieldName']);

################# Optional arguments ####################
has wantedChr => (is => 'ro', isa => 'Maybe[Str]');

# The features defined in the config file, not all tracks need features
# We allow people to set a feature type for each feature #- feature : int
# We store feature types separately since those are optional as well
has features => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  traits   => ['Array'],
  default  => sub{ [] },
  handles  => { 
    allFeatureNames => 'elements',
    noFeatures  => 'is_empty',
  },
);

# Public, but not expected to be set by calling class, derived from features
# in BUILDARG
has featureDataTypes => (
  is => 'ro',
  isa => 'HashRef[DataType]',
  lazy => 1,
  traits   => ['Hash'],
  default  => sub{{}},
  handles  => { 
    getFeatureType => 'get',
  },
);

# We allow a "nearest" property to be defined for any tracks
# Although it won't make sense for some (like reference)
# It's up to the consuming class to decide if they need it
# It is a property that, when set, may have 0 or more features
has nearest => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    noNearestFeatures => 'is_empty',
    allNearestFeatureNames => 'elements',
  },
  predicate => 'hasNearest',
  lazy => 1,
  default => sub{ [] },
);

has join => (is => 'ro', isa => 'Maybe[HashRef]', lazy => 1, default => undef);

has debug => ( is => 'ro', isa => 'Bool', lazy => 1, default => 0 );

#### Initialize / make dbnames for features and tracks before forking occurs ###
sub BUILD {
  my $self = shift;

  # getFieldDbNames is not a pure function; sideEffect of setting auto-generated dbNames in the
  # database the first time (ever) that it is run for a track
  # We could change this effect; for now, initialize here so that each thread
  # gets the same name
  for my $featureName ($self->allFeatureNames) {
    $self->getFieldDbName($featureName);
  }
  
  #Set the nearest track names first, because they may be applied genome wide
  #And if we use array format to store data (to save space) good to have
  #Genome-wide tracks have lower indexes, so that higher indexes can be used for 
  #sparser items, because we cannot store a sparse array, must store 1 byte per field
  if($self->hasNearest) {
    my $dbNameBuilder = Seq::Tracks::Base::MapTrackNames->new({name => $self->name . '.nearest'});

    $dbNameBuilder->buildDbName();

    $self->_setNearestDbName($dbNameBuilder->dbName);

    $self->log('debug', "Set " . $self->name . ' nearest dbName as ' . $self->nearestDbName);
  }

  my $dbNameBuilder = Seq::Tracks::Base::MapTrackNames->new({name => $self->name});

  $dbNameBuilder->buildDbName();

  $self->_setDbName($dbNameBuilder->dbName);

  $self->log('debug', "Track " . $self->name . " dbName is " . $self->dbName);

  if(defined $self->join ) {
    if(!defined $self->join->{track}) {
      $self->log('fatal', "'join' requires track key");
    }

    $self->_setJoinTrackName($self->join->{track});
    $self->_setJoinTrackFeatures($self->join->{features});
    
    #Each track gets its own private naming of join features
    #Since the track may choose to store these features as arrays
    #Again, needs to happen outside of thread, first time it's ever called
    if($self->joinTrackFeatures) {
      for my $feature (@{$self->joinTrackFeatures}) {
        $self->getFieldDbName($feature);
      }
    }
  }
}

############ Argument configuration to meet YAML config spec ###################

# Expects a hash, will crash and burn if it doesn't
sub BUILDARGS {
  my ($class, $data) = @_;

  # #don't mutate the input data
  # my %data = %$dataHref;
  
  if(defined $data->{chromosomes} &&  ref $data->{chromosomes} eq 'ARRAY') {
    my %chromosomes = map { $_ => 1 } @{$data->{chromosomes} };
    $data->{chromosomes} = \%chromosomes;
  }

  if(defined $data->{wantedChr} ) {
    if (exists $data->{chromosomes}->{$data->{wantedChr} } ) {
      $data->{chromosomes} = { $data->{wantedChr} => 1, };
    } else {
      $class->log('fatal', 'Wanted chromosome not listed in chromosomes in YAML config');
    }
  }

  if(! defined $data->{features} ) {
    return $data;
  }

  if( defined $data->{features} && ref $data->{features} ne 'ARRAY') {
    #This actually works :)
    $class->log('fatal', 'features must be array');
  }

  # If features are passed to as hashes (to accomodate their data type) get back to array
  my @featureLabels;

  for my $feature (@{$data->{features} } ) {
    if (ref $feature eq 'HASH') {
      my ($name, $type) = %$feature; #Thomas Wingo method

      push @featureLabels, $name;
      $data->{featureDataTypes}{$name} = $type;

      next;
    }
    
    push @featureLabels, $feature;
  }
  $data->{features} = \@featureLabels;

  # Currently requires features. Could allow for tracks w/o features in future
  if( defined $data->{nearest} ) {
    if( ref $data->{nearest} ne 'ARRAY' || !@{ $data->{nearest} } ) {
      $class->log('fatal', 'Cannot set "nearest" property without providing 
       an array of feature names');
    }
    
    for my $nearestFeatureName (@{ $data->{nearest} } ) {
      #~ takes a -1 and makes it a 0
      if(! ~first_index{ $_ eq $nearestFeatureName } @ { $data->{features} } ) {
        $class->log('fatal', "$nearestFeatureName, which you've defined under 
          the nearest property, doesn't exist in the list of $data->{name} 'feature' 
          properties");
      }
    }
  }
  
  return $data;
};

__PACKAGE__->meta->make_immutable;

1;
