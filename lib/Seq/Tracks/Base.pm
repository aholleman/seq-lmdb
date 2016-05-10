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
#specifies the allowed track types, and feature types
with 'Seq::Tracks::Base::Types',
'Seq::Role::DBManager';
# should be shared between all types
# Since Seq::Tracks;:Base is extended by every Track, this is an ok place for it.
# Could also use state, and not re-initialize it for every instance
# as stated in Seq::Tracks::Definition coercision here gives us chr => chr
# this saves us doing a scan of the entire array to see if we want a chr
# all this is used for is doing that check, so coercsion is appropriate

has name => ( is => 'ro', isa => 'Str', required => 1);

# has debug => ( is => 'ro', isa => 'Int', lazy => 1, default => 0);
#specifies the way we go from feature name to their database names and back
#requires name
with 'Seq::Tracks::Base::MapFieldNames',
#maps track names, which are used as to identify track data in the database
#to some shorter record which is actually stored in the db
'Seq::Tracks::Base::MapTrackNames';

#TrackType exported from Tracks::Base::Type
has type => ( is => 'ro', isa => 'TrackType', required => 1);

#We allow people to set a feature type for each feature
#But not all tracks must have a feature
#- feature : int
#but we need to store those types separately from the featureName
#since feature types are optional as well
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

#We allow a "nearest" property to be defined for any tracks
#Although it won't make sense for some (like reference)
#We could move it elsewhere, but the only track that can't use this
#Is the reference track, so I believe it belongs here
#It is a property that, when set, may have 0 or more features
has nearest => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    noNearestFeatures => 'is_empty',
    allNearestFeatureNames => 'elements',
  },
  lazy => 1,
  default => sub{ [] },
);

#we could explicitly check for whether a hash was passed
#but not doing so just means the program will crash and burn if they don't
#note that by not shifting we're implying that the user is submitting an href
#if they don't required attributes won't be found
#so the messages won't be any uglier
around BUILDARGS => sub {
  my ($orig, $class, $dataHref) = @_;

  #don't mutate the input data
  my %data = %$dataHref;

  if(! defined $data{features} ) {
    return $class->$orig(\%data);
  }

  if( ref $data{features} ne 'ARRAY') {
    #This actually works :)
    $class->log('fatal', 'features must be array');
  }

  #If features are passed to as hashes (to accomodate their data type)
  #get back to array
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

  #note that if you don't have any features listed, this part won't run
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

sub BUILD {
  my $self = shift;

  #this should happen first, becuase in multithreaded environment
  #we could get conflict as we try to write to the exact same resource
  #by multiple threads
  for my $featureName ($self->allFeatureNames) {
    $self->getFieldDbName($featureName);
  }
  
  $self->buildDbName();
}

#TODO: we should allow casting of required_fields.
#we'll expect that modules will constrain the hash ref values
#to what they require
#ex: 
# http://search.cpan.org/~ether/Moose-2.1605/lib/Moose/Util/TypeConstraints.pm
  # type 'HashOfArrayOfObjects',
  #     where {
  #         IsHashRef(
  #             -keys   => HasLength,
  #             -values => IsArrayRef(IsObject)
  #         )->(@_);
  #     };
# This is consistent with the Base class' handling of mapping to a db name
# It's basically, as always label : type
# Label is expected (for features, and required_fields) to map exactly to
# what the user has in their db


# I'm moving away from the required field thing
#Required fields is a bit hacky, because they're not usually stored 
#explicitly
# has required_fields => (
#   is => 'ro',
#   isa => 'HashRef',
#   traits => ['Hash'],
#   lazy => 1,
#   default => sub{ {} },
#   handles => {
#     allReqFieldNames => 'keys',
#     getReqFieldDbName => 'get', 
#     noRequiredFields  => 'is_empty',
#   },
# );

# has _requiredFieldDataTypes => (
#   is => 'ro',
#   isa => 'HashRef[DataType]',
#   traits => ['Hash'],
#   lazy => 1,
#   default => sub{ {} },
#   handles => {
#     getReqFieldType => 'get',
#     noReqFieldTypes  => 'is_empty',
#   },
# );

__PACKAGE__->meta->make_immutable;

1;
