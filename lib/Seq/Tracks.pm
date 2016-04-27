#Initializes SingletonTracks, which constructs all of our tracks according to the
#config file
#and also sets the database path, which is also a singleton
use 5.10.0;
use strict;
use warnings;
our $VERSION = '0.002';

package Seq::Tracks;

# ABSTRACT: A base class for track classes
# VERSION

use Moose 2;
use namespace::autoclean;

use MooseX::Types::Path::Tiny qw/AbsPath AbsDir/;

#holds a permanent record of all of the tracks
extends 'Seq::Tracks::SingletonTracks';

with 'Seq::Role::ConfigFromFile',
#we configure the db manager here
'Seq::Role::DBManager';

# has debug => ( is => 'ro', isa => 'Int', lazy => 1, default => 0);

# used to simplify process of detecting tracks
# I think that Tracks.pm should know which features it has access to
# and anything conforming to that interface should become an instance
# of the appropriate class
# and everythign else shouldn't, and should generate a warning
# This is heavily inspired by Dr. Thomas Wingo's primer picking software design
# expects structure to be {
#  trackName : {typeStuff},
#  typeName2 : {typeStuff2},
#}

#We don't instantiate a new object for each data source
#Instead, we simply create a container for each name : type pair
#We could use an array, but a hash is easier to reason about
#We also expect that each record will be identified by its track name
#so (in db) {
#   trackName : {
#     featureName: featureValue  
#} 
#}

sub BUILD {
  my $self = shift;

  if(!$self->database_dir->exists) {
    say "database dir doesnt exist";
    $self->database_dir->mkpath;
  } elsif (!$self->database_dir->is_dir) {
    return $self->log('error', 'database_dir given is not a directory');
  }
  
  #needs to be initialized before dbmanager can be used
  $self->setDbPath( $self->database_dir );

  #This is not strictly necessary, but shows intent and wastes little time
  $self->initializeTrackBuildersAndGetters();
}

__PACKAGE__->meta->make_immutable;

1;
