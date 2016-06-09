#Initializes SingletonTracks, which constructs all of our tracks according to the
#config file
#and also sets the database path, which is also a singleton
use 5.10.0;
use strict;
use warnings;
our $VERSION = '0.002';

package Seq::Tracks;

# ABSTRACT: A base class for track classes

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

# VERSION

use Moose 2;
use namespace::autoclean;

#holds a permanent record of all of the tracks
use Seq::Tracks::SingletonTracks;

#exports new_with_config
with 'Seq::Role::ConfigFromFile',
#exports all the methods prefaced with db* like dbGet
'Seq::Role::DBManager';

#the only property we mean to export
has singletonTracks => (
  is => 'ro',
  isa => 'Seq::Tracks::SingletonTracks',
  init_arg => undef,
  writer => '_setSingletonTracks',
  lazy => 1,
  default => sub {
    my $self = shift;
    return Seq::Tracks::SingletonTracks->new( {tracks => $self->tracks} );
  }
);

# attributes that are given to this class as configuration options

#our only required value; needed for SingletonTracks
has tracks => (
  is => 'ro',
  required => 1,
);

has messanger => (
  is => 'ro',
  isa => 'Maybe[HashRef]',
  lazy => 1,
  default => undef,
);

has publisherAddress => (
  is => 'ro',
  isa => 'Maybe[ArrayRef]',
  lazy => 1,
  default => undef,
);

has logPath => (
  is => 'ro',
  lazy => 1,
  default => '',
);

has debug => (
  is => 'ro',
  lazy => 1,
  default => 0,
);

sub BUILD {
  my $self = shift;

  if(!$self->database_dir->exists) {
    $self->log('debug', 'database_dir '. $self->database_dir . 'doesn\'t exit. Creating');
    $self->database_dir->mkpath;
  }

  if (!$self->database_dir->is_dir) {
    $self->log('fatal', 'database_dir given is not a directory');
  }
  
  #needs to be initialized before dbmanager can be used
  $self->setDbPath( $self->database_dir );

  if($self->messanger && $self->publisherAddress) {
    $self->setPublisher($self->messanger, $self->publisherAddress);
  }

  if ($self->logPath) {
    $self->setLogPath($self->logPath);
  }

  #todo: finisih ;for now we have only one level
  if ( $self->debug) {
    $self->setLogLevel('DEBUG');
  } else {
    $self->setLogLevel('INFO');
  }
}

__PACKAGE__->meta->make_immutable;

1;
