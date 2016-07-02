#This package stores track names as some integer
#if the user gives us a database name, we can store that as well
#they would do that by :
# name: 
#   someName : someValue

use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base::MapTrackNames;
use Moose 2;
use List::Util qw/max/;
use DDP;

with 'Seq::Role::Message', 'Seq::Role::DBManager';

# The name of the track is required
has name => ( is => 'ro', isa => 'Str', required => 1 );

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
  init_arg => undef,
  lazy => 1,
  builder => 'buildDbName',
);

#Under which key fields are mapped in the meta database belonging to the
#consuming class' $self->name
#in roles that extend this role, this key's default can be overloaded

state $metaKey = 'name';

#For a $self->name (track name) get a specific field database name
#Expected to be used during database building
#If the fieldName doesn't have a corresponding database name, make one, store,
#and return it
sub buildDbName {
  my $self = shift;
    
  if (!exists $trackNamesMap->{$self->name} ) {
    $self->_fetchTrackNameMeta();
  }

  # If after fetching it still doesn't exist, we need to add it
  if(!exists $trackNamesMap->{$self->name} ) {
    $self->_addTrackNameMeta();
  }

  return $trackNamesMap->{$self->name};
}

sub _fetchTrackNameMeta {
  my $self = shift;

  my $nameNumber = $self->dbReadMeta($self->name, $metaKey) ;

  #if we don't find anything, just store a new hash reference
  #to keep a consistent data type
  if( !defined $nameNumber ) {
    return;
  }
  
  $trackNamesMap->{$self->name} = $nameNumber;

  #fieldNames map is name => dbName; dbNamesMap is the inverse
  $trackDbNamesMap->{ $nameNumber } = $self->name;
}

sub _addTrackNameMeta {
  my $self = shift;

  my @trackNumbers = keys %$trackDbNamesMap;
  
  my $nameNumber;
  if(!@trackNumbers) {
    $nameNumber = 0;
  } else {
    #https://ideone.com/eX3dOh
    $nameNumber = max(@trackNumbers) + 1;
  }

  $self->log('debug', "adding a new track name to the ". $self->name ." meta database" );
  $self->log('debug', "for " . $self->name ." we'll use a dbName of ");
  
  #need a way of checking if the insertion actually worked
  #but that may be difficult with the currrent LMDB_File API
  #I've had very bad performance returning errors from transactions
  #which are exposed in the C api
  #but I may have mistook one issue for another
  $self->dbPatchMeta($self->name, $metaKey, $nameNumber);

  $trackNamesMap->{$self->name} = $nameNumber;
  $trackDbNamesMap->{$nameNumber} = $self->name;
}

__PACKAGE__->meta->make_immutable;
1;