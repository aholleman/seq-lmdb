use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base;
#Every track class extends this. The attributes detailed within are used
#regardless of whether we're building or annotating
#and nothing else ends up here (for instance, required_fields goes to Tracks::Build) 

our $VERSION = '0.001';

use Moose 2;
use DDP;
use List::MoreUtils qw/first_index/;

use Seq::Tracks::Base::MapTrackNames;

# TODO: move Base::Types  to a role
#exports TrackType, DataTypes
with 'Seq::Tracks::Base::Types',
# exports db* methods, overwrite, delete, dbReadOnly, database_dir attributes
'Seq::Role::DBManager';

###################### Required Arguments ############################
# the track name
has name => ( is => 'ro', isa => 'Str', required => 1);

#TrackType exported from Tracks::Base::Type
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

# Exports getFieldName and getFieldDbName , requires name
# TODO: move this to a class instead of role
with 'Seq::Tracks::Base::MapFieldNames';

################# Optional arguments ####################
has wantedChr => (
  is => 'ro',
  isa => 'Maybe[Str]',
  lazy => 1,
  default => undef,
);

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

################# Public Exports ##########################
# Note the -9; this means we MUST set this in our BUILD method here (or a consuming track in their BUILD)
has dbName => ( is => 'ro', init_arg => undef, lazy => 1, writer => '_setDbName', default => -9, );

# Some tracks may have a nearest property; these are stored as their own track, but
# conceptually are a sub-track, 
has nearestName => ( is => 'ro', init_arg => undef, lazy => 1, default => 'nearest');

has nearestDbName => ( is => 'ro', init_arg => undef, lazy => 1, writer => '_setNearestDbName', default => -9, );

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

    if($self->debug) {
      say "set " . $self->name . ' nearest dbName as ' . $self->nearestDbName;
    }
  }

  my $dbNameBuilder = Seq::Tracks::Base::MapTrackNames->new({name => $self->name});

  $dbNameBuilder->buildDbName();

  $self->_setDbName($dbNameBuilder->dbName);

  if($self->debug) {
    say "track name is " . $self->name; say "track dbName is " . $self->dbName;
  }
}

############ Argument configuration to meet YAML config spec ###################

# Expects a hash, will crash and burn if it doesn't
around BUILDARGS => sub {
  my ($orig, $class, $dataHref) = @_;

  #don't mutate the input data
  my %data = %$dataHref;

  if(defined $data{chromosomes} &&  ref $data{chromosomes} eq 'ARRAY') {
    my %chromosomes = map { $_ => 1 } @{$data{chromosomes} };
    $data{chromosomes} = \%chromosomes;
  }

  if(defined $data{wantedChr} ) {
    if (exists $data{chromosomes}->{$data{wantedChr} } ) {
      $data{chromosomes} = { $data{wantedChr} => 1, };
    } else {
      $class->log('fatal', 'Wanted chromosome not listed in chromosomes in YAML config');
    }
  }

  if(! defined $data{features} ) {
    return $class->$orig(\%data);
  }

  if( defined $data{features} && ref $data{features} ne 'ARRAY') {
    #This actually works :)
    $class->log('fatal', 'features must be array');
  }

  # If features are passed to as hashes (to accomodate their data type) get back to array
  my @featureLabels;

  for my $feature (@{$data{features} } ) {
    if (ref $feature eq 'HASH') {
      my ($name, $type) = %$feature; #Thomas Wingo method

      push @featureLabels, $name;
      $data{_featureDataTypes}{$name} = $type;

      next;
    }
    
    push @featureLabels, $feature;
  }
  $data{features} = \@featureLabels;

  # Currently requires features. Could allow for tracks w/o features in future
  if( defined $data{nearest} ) {
    if( ref $data{nearest} ne 'ARRAY' || !@{ $data{nearest} } ) {
      $class->log('fatal', 'Cannot set "nearest" property without providing 
       an array of feature names');
    }
    
    for my $nearestFeatureName (@{ $data{nearest} } ) {
      #~ takes a -1 and makes it a 0
      if(! ~first_index{ $_ eq $nearestFeatureName } @ { $data{features} } ) {
        $class->log('fatal', "$nearestFeatureName, which you've defined under 
          the nearest property, doesn't exist in the list of $data{name} 'feature' 
          properties");
      }
    }
  }
  
  return $class->$orig(\%data);
};

__PACKAGE__->meta->make_immutable;

1;
