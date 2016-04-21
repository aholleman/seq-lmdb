use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base;
#Every track class extends this. The attributes detailed within are used
#regardless of whether we're building or annotating
#and nothing else ends up here (for instance, required_fields goes to Tracks::Build) 

our $VERSION = '0.001';

use Moose 2;
#DBManager not used here, but let's make it accessible to those that inherit this class
with 'Seq::Role::DBManager', 'Seq::Tracks::Base::Definition', 'Seq::Role::Message';
# should be shared between all types
# Since Seq::Tracks;:Base is extended by every Track, this is an ok place for it.
# Could also use state, and not re-initialize it for every instance
# as stated in Seq::Tracks::Definition coercision here gives us chr => chr
# this saves us doing a scan of the entire array to see if we want a chr
# all this is used for is doing that check, so coercsion is appropriate
has genome_chrs => (
  is => 'ro',
  isa => 'HashRef',
  coerce => 1,
  traits => ['Hash'],
  handles => {
    'allWantedChrs' => 'keys',
    'chrIsWanted' => 'defined',
  },
  lazy_build => 1,
);

#TODO: don't use YAML config to choose dbNames, do that internally, store in
#a special config/info database, which contains information like
#whether the feature finished building (per chr), and maybe how many entries it has
#and the feature mappings (which update to accomodate new features specified in YAML)
#and what the track db names are
#we should also record a history of feature types, in case the user changes those
#could be important for research reproducibility (float, int)
#the "noFeatures", "noDataTypes" is really ugly; unfortunately
#moose doesn't allow traits + Maybe or Undef types
#could defined data types here,
#but then getting feature names is more awkward
#ArrayRef[Str | Maybe[HashRef[DataType] ] ]
has features => (
  is => 'ro',
  isa => 'HashRef[Str]',
  lazy => 1,
  traits   => ['Hash'],
  default  => sub{ {} },
  handles  => { 
    allFeatureNames => 'keys',
    getFeatureDbName => 'get',
    noFeatures  => 'is_empty',
    featureNamesKv => 'kv',
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


has name => ( is => 'ro', isa => 'Str', required => 1);

#we internally store the name as an integer, to save db space
#default is just the name itself; but see buildargs below
#not meant to be set in YAML config; user could easily screw up mappings
#and its an internal API consideration, no benefit for public
has _dbName => ( reader => 'dbName', is => 'ro', isa => 'Str', lazy => 1,
  default => sub { my $self = shift; return $self->name; }
);

has type => ( is => 'ro', isa => 'Str', required => 1);

#we could explicitly check for whether a hash was passed
#but not doing so just means the program will crash and burn if they don't
#note that by not shifting we're implying that the user is submitting an href
#if they don't required attributes won't be found
#so the messages won't be any uglier
around BUILDARGS => sub {
  my ($orig, $class, $data) = @_;

  if(!defined $data->{features} ) {
    return $class->$orig($data);
  }

  if( ref $data->{features} ne 'ARRAY') {
    $class->tee_logger('error', 'features must be array');
    die 'features must be array';
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
        #must use defined to allow 0 values
        if( defined $type->{store} ) {
          $featureLabels{$name} = $type->{store};
        }
        #must use defined to allow 0 values (not as nec. here, because 0 type is weird)
        if( defined $type->{type} ) {
          #need to use the label, because that is the name that we use
          #internally
          $data->{_featureDataTypes}{$featureLabels{$name} } = $type->{type};
        }

        next;
      }

      $featureLabels{$name} = $name;
      $data->{_featureDataTypes}{$name} = $type;
    }
  }
  $data->{features} = \%featureLabels;

  #now do the same for required_fields
  if( !defined $data->{required_fields} ) {
    return $class->$orig($data);
  }

  if( ref $data->{required_fields} ne 'ARRAY') {
    $class->tee_logger('error', 'required_fields must be array');
    die 'required_fields must be array';
  }

  #we convert the features into a hashRef
  # {
  #  featureNameAsAppearsInHeader => <Str> (what we store it as)
  #}
  my %reqFieldLabels;
  for my $field (@{$data->{required_fields} } ) {
    if (ref $field eq 'HASH') {
      my ($name, $type) = %$field; #Thomas Wingo method

      #users can explicilty tell us what they want
      #-features:
        # blah:
          # - type : int
          # - store : b
      if(ref $type eq 'HASH') {
        #must use defined to allow 0 values
        if( defined $type->{store} ) {
          $reqFieldLabels{$name} = $type->{store};
        }
        #must use defined to allow 0 values (not as nec. here, because 0 type is weird)
        if( defined $type->{type} ) {
          #need to use the label, because that is the name that we use
          #internally
          $data->{_requiredFieldDataTypes}{$reqFieldLabels{$name} } = $type->{type};
        }

        next;
      }

      $reqFieldLabels{$name} = $name;
      $data->{_requiredFieldDataTypes}{$name} = $type;
    }
  }
  $data->{required_fields} = \%reqFieldLabels;

  $class->$orig($data);
};

# sub get {
#   my $self = shift;
#   #the entire hash from the main database
#   my $dataHref = shift;

  
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


__PACKAGE__->meta->make_immutable;

1;
