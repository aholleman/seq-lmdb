use 5.10.0;
use strict;
use warnings;

package Utils::Base;

# A base class for utilities. Just a place to store common attributes

use Mouse 2;

with 'Seq::Role::Message';
with 'Seq::Role::IO';

use Types::Path::Tiny qw/AbsFile/;
use List::MoreUtils qw/first_index/;
use YAML::XS qw/LoadFile Dump/;
use Path::Tiny qw/path/;

my $localtime = join("_", split(" ", localtime) );

############## Arguments accepted #############
# The track name that they want to use
has name => (is => 'ro', isa => 'Str', required => 1);

# The YAML config file path
has config => ( is => 'ro',isa => AbsFile, coerce => 1, required => 1, handles => {
    configPath => 'stringify'});

# Logging
has logPath => ( is => 'ro', lazy => 1, default => sub {
  my $self = shift; return "./utils_" . $self->name . ".$localtime.log";
});

# Debug log level?
has debug => (is => 'ro');

# Compress the output?
has compress => (is => 'ro');

# Overwrite files if they exist?
has overwrite => (is => 'ro');

has publisher => (is => 'ro');

has verbose => (is => 'ro');

#########'Protected' vars (Meant to be used by child class only) ############ 
has _wantedTrack => ( is => 'ro', init_arg => undef, writer => '_setWantedTrack' );

has _decodedConfig => ( is => 'ro', isa => 'HashRef', lazy => 1, default => sub {
  my $self = shift; return LoadFile($self->configPath);
});

# Where any downloaded or created files should be saved
has _localFilesDir => ( is => 'ro', isa => 'Str', lazy => 1, default => sub {
  my $self = shift;
  my $dir = path($self->_decodedConfig->{files_dir})->child($self->_wantedTrack->{name});
  
  if(!$dir->exists) {
    $dir->mkpath;
  }
  
  return $dir->stringify;
});

has _newConfigPath => ( is => 'ro', isa => 'Str', lazy => 1, default => sub {
  my $self = shift;

  return substr($self->configPath, 0, rindex($self->config,'.') ) . ".$localtime"
    . substr($self->config, rindex($self->config,'.') );
});

sub BUILD {
  my $self = shift;

  # If in long-running process, clear singleton state
  Seq::Role::Message::initialize();

  # Seq::Role::Message settings
  # We manually set the publisher, logPath, verbosity, and debug, because
  # Seq::Role::Message is meant to be consumed globally, but configured once
  # Treating publisher, logPath, verbose, debug as instance variables
  # would result in having to configure this class in every consuming class
  if($self->publisher) {
    $self->setPublisher($self->publisher);
  }

  if ($self->logPath) {
    $self->setLogPath($self->logPath);
  }

  if($self->verbose) {
    $self->setVerbosity($self->verbose);
  }

  #todo: finisih ;for now we have only one level
  if ( $self->debug) {
    $self->setLogLevel('DEBUG');
  } else {
    $self->setLogLevel('INFO');
  }

  # Must happen here, because we need to account for the case where track isn't found
  # And you cannot throw an error from within a default, and I think it is
  # More clear to throw a fatal error from the BUILD method than a builder=> method
  my $trackIndex = first_index { $_->{name} eq $self->name } @{ $self->_decodedConfig->{tracks} };
  
  if($trackIndex == -1) {
    $self->log('fatal', "Desired track " . $self->name . " wasn't found");
    return;
  }

  $self->_setWantedTrack( $self->_decodedConfig->{tracks}[$trackIndex] );
}

sub _backupAndWriteConfig {
  my $self = shift;

  # If this is already a symlink, remove it
  if(-l $self->configPath) {
    unlink $self->configPath;
  } else {
    if( system ("mv " . $self->configPath . " " . $self->configPath . ".bak.$localtime" ) != 0 ) {
      $self->log('fatal', "Failed to back up " . $self->configPath);
    }
  }

  open(my $fh, '>', $self->_newConfigPath) or $self->log('fatal', "Couldn't open"
    . $self->_newConfigPath . " for writing" );

  say $fh Dump($self->_decodedConfig);

  # -f forces hard link / overwrite
  if( system ("ln -f " . $self->_newConfigPath . " " . $self->configPath) != 0 ) {
    $self->log('fatal', "Failed to hard link " . $self->configPath . " to " . $self->_newConfigPath);
  }
}

__PACKAGE__->meta->make_immutable;
1;
