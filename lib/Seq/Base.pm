use 5.10.0;
use strict;
use warnings;
our $VERSION = '0.002';

package Seq::Base;

# ABSTRACT: Configures singleton log and sets database directory

# Also exports db object, since we configure the database class anyway

# VERSION

use Mouse 2;
use namespace::autoclean;
use Seq::DBManager;
use DDP;
#exports new_with_config
with 'Seq::Role::ConfigFromFile', 
#setLogLevel, setLogPath, setPublisher
'Seq::Role::Message',
############# Required Arguments ###########
has database_dir => (is => 'ro', required => 1);

############# Optional Arguments #############
has publisher => (is => 'ro');

has logPath => (is => 'ro');

has debug => (is => 'ro');

has verbose => (is => 'ro');

sub BUILD {
  my $self = shift;

  # DBManager acts as a singleton. It is configured once, and then consumed repeatedly
  # However, in long running processes, this can lead to misconfiguration issues
  # and worse, environments created in one process, then copied during forking, to others
  # To combat this, every time Seq::Base is called, we re-set/initialzied the static
  # properties that create this behavior
  Seq::DBManager::initialize();

  # Since we never have more than one database_dir, it's a global property we can set
  # in this package, which Seq.pm and Seq::Build extend from
  Seq::DBManager::setGlobalDatabaseDir($self->database_dir);

  # Similarly Seq::Role::Message acts as a singleton
  # Clear previous consumer's state, if in long-running process
  Seq::Role::Message::initialize();

  # Seq::Role::Message settings
  # We manually set the publisher, logPath, verbosity, and debug, because
  # Seq::Role::Message is meant to be consumed globally, but configured once
  # Treating publisher, logPath, verbose, debug as instance variables
  # would result in having to configure this class in every consuming class
  if(defined $self->publisher) {
    $self->setPublisher($self->publisher);
  }

  if (defined $self->logPath) {
    $self->setLogPath($self->logPath);
  }

  if(defined $self->verbose) {
    $self->setVerbosity($self->verbose);
  }

  #todo: finisih ;for now we have only one level
  if (defined $self->debug) {
    $self->setLogLevel('DEBUG');
  } else {
    $self->setLogLevel('INFO');
  }
}

__PACKAGE__->meta->make_immutable;

1;
