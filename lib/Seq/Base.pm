use 5.10.0;
use strict;
use warnings;
our $VERSION = '0.002';

package Seq::Base;

# ABSTRACT: Take care of basic configuration for stuff needed everywhere

# VERSION

use Moose 2;
use namespace::autoclean;

#exports new_with_config
with 'Seq::Role::ConfigFromFile', 
#setLogLevel, setLogPath, setPublisher
'Seq::Role::Message',
#exports all the methods prefaced with db* like dbGet
'Seq::Role::DBManager';

has publisherMessageBase => (
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

  if($self->publisherMessageBase && $self->publisherAddress) {
    $self->setPublisher($self->publisherMessageBase, $self->publisherAddress);
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
