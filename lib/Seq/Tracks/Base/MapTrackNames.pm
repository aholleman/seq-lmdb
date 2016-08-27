#This package stores track names as some integer
#if the user gives us a database name, we can store that as well
#they would do that by :
# name: 
#   someName : someValue

use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base::MapTrackNames;
use Mouse 2;
use List::Util qw/max/;
use DDP;
use Seq::DBManager;

with 'Seq::Role::Message';

################### Public Exports ##########################
# The name of the track is required
has name => ( is => 'ro', isa => 'Str', required => 1 );

# Unlike MapFieldNames, there is only a single name for each $self->name
# So, we store this into a memoized name.
has dbName => (is => 'ro', init_arg => undef, lazy => 1, builder => 'buildDbName');

has db => (is => 'ro', init_arg => undef, lazy => 1, default => sub {
  return Seq::DBManager->new();
});
############## Private variables ##############
#Unlike MapFieldNames, this class stores meta for all tracks
#We may move MapFieldNames to a similar system if it proves more efficient
#the hash of names => dbName map
state $trackNamesMap = {};
#the hash of dbNames => names
state $trackDbNamesMap = {};

# Track names are stroed under a database ('table') called $self->name_$metaKey
my $metaKey = 'name';

####################### Public methods ################
#For a $self->name (track name) get a specific field database name
#Expected to be used during database building
#If the fieldName doesn't have a corresponding database name, make one, store,
#and return it
sub buildDbName {
  my $self = shift;
      
  # p $trackNamesMap;
  
  if (!exists $trackNamesMap->{$self->name} ) {
    $self->_fetchTrackNameMeta();
  }

  # If after fetching it still doesn't exist, we need to add it
  if(!exists $trackNamesMap->{$self->name} ) {
    $self->_addTrackNameMeta();
  }

  return $trackNamesMap->{$self->name};
}

################### Private Methods ###################

sub _fetchTrackNameMeta {
  my $self = shift;

  my $nameNumber = $self->db->dbReadMeta($self->name, $metaKey) ;

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

  if(!exists $trackDbNamesMap->{$self->name} ) {
    $trackDbNamesMap->{$self->name} = {};
  }

  my @trackNumbers = keys %{$trackDbNamesMap->{$self->name} };
  
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
  $self->db->dbPatchMeta($self->name, $metaKey, $nameNumber);

  $trackNamesMap->{$self->name} = $nameNumber;
  $trackDbNamesMap->{$nameNumber} = $self->name;
}

__PACKAGE__->meta->make_immutable;
1;