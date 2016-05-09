#This package stores track names as some integer
#if the user gives us a database name, we can store that as well
#they would do that by :
# name: 
#   someName : someValue

use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base::MapTrackNames;
use Moose::Role;
use List::Util qw/max/;
use DDP;

with 'Seq::Role::Message', 'Seq::Role::DBManager';

#the feature name
requires 'name';

#Unlike MapFieldNames, this class stores meta for all tracks
#We may move MapFieldNames to a similar system if it proves more efficient
#the hash of names => dbName map
state $trackNamesMap = {};
#the hash of dbNames => names
state $trackDbNamesMap = {};

# Unlike MapFieldNames, there is only a single name for each $self->name
# So, we store this into a memoized name.
has dbName => (
  is => 'ro',
  isa => 'Str',
  ini_arg => undef,
  lazy => 1,
  _builder => '_buildDbName',
);

#Under which key fields are mapped in the meta database belonging to the
#consuming class' $self->name
#in roles that extend this role, this key's default can be overloaded
has metaKey => (
  is => 'ro',
  isa => 'Str',
  init_arg => undef,
  lazy => 1,
  default => 'name',
);

state $metaDatabaseName = 'all_tracks';

#For a $self->name (track name) get a specific field database name
#Expected to be used during database building
#If the fieldName doesn't have a corresponding database name, make one, store,
#and return it
sub _buildDbName {
  my ($self) = @_;

  if (! exists $trackNamesMap->{$self->name} ) {
    $self->_fetchTrackNameMeta();
  }

  if(!exists $trackNamesMap->{$self->name} ) {
    $self->_addTrackNameMeta();
  }

  if($self->debug) {
    say "after fetchMetaFields, trackNamesMap is";
    p $trackNamesMap;
    say "and trackDbNamesMap is";
    p $trackDbNamesMap;
  }

  return $trackNamesMap->{$self->name};
}

sub _fetchTrackNameMeta {
  my $self = shift;

  #expects {
  #  name => dbName
  #}
  my $nameHref = $self->dbReadMeta($metaDatabaseName, $self->metaKey) ;

  #if we don't find anything, just store a new hash reference
  #to keep a consistent data type
  if( !$nameHref ) {
    return;
  }
  
  $trackNamesMap = $nameHref;

  #fieldNames map is name => dbName; dbNamesMap is the inverse
  for my $trackName (keys %$nameHref ) {
    $trackDbNamesMap->{$trackName} = $nameHref->{$trackName};
  }
}

sub _addTrackNameMeta {
  my $self = shift;

  # say "in addMetaField we want";
  # p $fieldName;
  # say "fieldDbNamesMap for ". $self->name . " is";
  # p $fieldDbNamesMap->{$self->name};

  my @trackNames = keys %$trackNamesMap;
  
  # say "keys are";
  # p @fieldKeys;
  
  my $nameNumber;
  if(!@trackNames) {
    $nameNumber = 0;
  } else {
    #https://ideone.com/eX3dOh
    $nameNumber = max(@trackNames) + 1;
  }

  # say "mapping is";
  # p $mapping;

  #need a way of checking if the insertion actually worked
  #but that may be difficult with the currrent LMDB_File API
  #I've had very bad performance returning errors from transactions
  #which are exposed in the C api
  #but I may have mistook one issue for another
  $self->dbPatchMeta($metaDatabaseName, $self->metaKey, {
    $self->name => $nameNumber,
  });

  $trackNamesMap->{$self->name} = $nameNumber;
  $trackDbNamesMap->{$nameNumber} = $self->name;
}
no Moose::Role;
1;