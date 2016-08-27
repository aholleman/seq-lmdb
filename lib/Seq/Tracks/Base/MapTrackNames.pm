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


############## Private variables ##############
#_db shouldn't be static, because in long running environment, can lead to 
# the wrong db config being used in a run
has _db => (is => 'ro', init_arg => undef, lazy => 1, default => sub {
  return Seq::DBManager->new();
});

# Track names are stroed under a database ('table') called $self->name_$metaKey
my $metaDb = 'trackNames';

####################### Public methods ################
# Look in the $trackName meta database (create if not exit), for a "name" => dbNameInt
# pair. If none found, create one (by iterating the max found)
# @param $trackName: Some name that we call a track name
sub getOrMakeDbName {
  my $self = shift;
  my $trackName = shift;
      
  # p $trackNamesMap;
  my $trackNumber = $self->_db->dbReadMeta($metaDb, $trackName);

  #if we don't find anything, just store a new hash reference
  #to keep a consistent data type
  if( !defined $trackNumber ) {
    $self->log('debug', "Creating new trackNmber for $trackName");
    
    $trackNumber = $self->_addTrackNameMeta($trackName);

    $self->log('debug', "Created new max trackNumber $trackNumber");
  }

  return $trackNumber;
}

sub renameTrack {
  my ($self, $trackName, $newTrackName) = @_;

  my $trackNumber = $self->_db->dbReadMeta($metaDb, $trackName);

  if(!defined $trackNumber) {
    return $self->log('warn', "Couldn't find an existing trackNumber for track $trackName"
      . " Therefore skipping renameTrack operation");
  }

  # pass 1 as 4th argument to signify that we're deleting
  $self->_db->dbDeleteMeta($metaDb, $trackName);

  $self->_db->dbPatchMeta($metaDb, $newTrackName, $trackNumber);
}

################### Private Methods ###################
sub _addTrackNameMeta {
  my $self = shift;
  my $trackName = shift;

  state $largetTrackNumberKey = '_largestTrackNumber';
  
  my $maxNumber = $self->_db->dbReadMeta($metaDb, $largetTrackNumberKey);

  my $trackNumber;
  if(!defined $maxNumber) {
    $trackNumber = 0;
  } else {
    $trackNumber = $maxNumber + 1;
  }

  #need a way of checking if the insertion actually worked
  #but that may be difficult with the currrent LMDB_File API
  #I've had very bad performance returning errors from transactions
  #which are exposed in the C api
  #but I may have mistook one issue for another
  $self->_db->dbPatchMeta($metaDb, $trackName, $trackNumber);
  $self->_db->dbPatchMeta($metaDb, $largetTrackNumberKey, $trackNumber);

  return $trackNumber;
}

__PACKAGE__->meta->make_immutable;
1;