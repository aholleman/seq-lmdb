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

#TrackType exported from Tracks::Base::Type
has type => ( is => 'ro', isa => 'TrackType', required => 1);

#if the user gives us a database name, we can store that as well
#they would do that by :
# name: 
#   someName : someValue
has _dbName => ( reader => 'dbName', is => 'ro', isa => 'Str', lazy => 1,
  default => sub { my $self = shift; return $self->name; }
);

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

# has debug => ( is => 'ro', isa => 'Int', lazy => 1, default => 0);
#specifies the way we go from feature name to their database names and back
with 'Seq::Tracks::Base::MapFieldNames';

#we could explicitly check for whether a hash was passed
#but not doing so just means the program will crash and burn if they don't
#note that by not shifting we're implying that the user is submitting an href
#if they don't required attributes won't be found
#so the messages won't be any uglier
around BUILDARGS => sub {
  my ($orig, $class, $dataHref) = @_;

  #don't mutate the input data
  my %data = %$dataHref;
  if(ref $data{name} eq 'HASH') {
    ( $data{name}, $data{_dbName} ) = %{ $data{name} };
  }
  
  if(! defined $data{features} ) {
    return $class->$orig(\%data);
  }

  if( ref $data{features} ne 'ARRAY') {
    #Does this logging actually work? todo: test
    $class->log('error', 'features must be array');
    die 'features must be array';
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

  #now do the same for required_fields, if specified
  #This is currently not implemented
  #The only goal here is to allow people to tell Seqant what their source file
  #looks like, so that they don't have to manipulate large source file headers
  #help them avoid using command lilne
  #However, this is a relatively minor concern; few will be doing this
    # if( !defined $data{required_fields} ) {
    #   return $class->$orig($data);
    # }

    # if( ref $data{required_fields} ne 'ARRAY') {
    #   $class->log('error', 'required_fields must be array');
    #   die 'required_fields must be array';
    # }

    # #we convert the features into a hashRef
    # # {
    # #  featureNameAsAppearsInHeader => <Str> (what we store it as)
    # #}
    # my %reqFieldLabels;
    # for my $field (@{$data{required_fields} } ) {
    #   if (ref $field eq 'HASH') {
    #     my ($name, $type) = %$field; #Thomas Wingo method

    #     $reqFieldLabels{$name} = $name;
    #     $data{_requiredFieldDataTypes}{$name} = $type;
    #   }
    # }
    # $data{required_fields} = \%reqFieldLabels;

  return $class->$orig(\%data);
};

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
