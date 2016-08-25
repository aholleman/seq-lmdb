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

sub BUILD {
  my $self = shift;

  # DBManager has two singleton properties
  # 1) database_dir : Where our database resides (accepted from command line or YAML)
  # 2) readOnly : Whether we plan to do any writing.
  # Since we never have more than one database_dir, it's a global property we can set
  # in this package, which Seq.pm and Seq::Build extend from
  Seq::DBManager->setGlobalDatabaseDir($self->database_dir);

  # Seq::Role::Message settigns
  if($self->publisher) {
    $self->setPublisher($self->publisher);
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
