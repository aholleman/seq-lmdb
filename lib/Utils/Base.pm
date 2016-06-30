use 5.10.0;
use strict;
use warnings;

package Utils::Base;

# A base class for utilities. Just a place to store common attributes

use Moose 2;

with 'Seq::Role::Message';
with 'Seq::Role::IO';

use List::MoreUtils qw/first_index/;
use YAML::XS qw/LoadFile Dump/;
use Path::Tiny qw/path/;

############## Public exports ################
has updatedConfig => (
  is => 'ro',
  init_arg => undef,
  writer => '_setUpdatedConfig',
  reader => 'getUpdatedConfigPath'
);

############## Arguments accepted #############
# The track name that they want to split
has wantedName => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# The YAML config file
has config => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# Logging
has logPath => ( is => 'ro', lazy => 1, default => sub {
  my $self = shift; return "./fetch_" . $self->wantedName . ".log";
});

# Debug log level?
has debug => (
  is => 'ro',
  lazy => 1,
  default => 0,
);

# Compress the output?
has compress => (
  is => 'ro',
  lazy => 1,
  default => 0,
);

has publisherMessageBase => (is => 'ro', lazy => 1, default => undef);
has publisherAddress => (is => 'ro', lazy => 1, default => undef);

#########'Protected' Vars (Meant to be used by child class only) ############ 
has _decodedConfig => ( is => 'ro', isa => 'HashRef', lazy => 1, default => sub {
  my $self = shift; return LoadFile($self->config);
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

has _wantedTrack => ( is => 'ro', isa => 'HashRef', lazy => 1, default => sub{
  my $self = shift;
  my $trackIndex = first_index {$_->{name} eq $self->wantedName} @{$self->_decodedConfig->{tracks}};
  return $self->_decodedConfig->{tracks}[$trackIndex];
});

has _newConfigPath => ( is => 'ro', isa => 'Str', lazy => 1, default => sub {
  my $self = shift;

  return substr($self->config, 0, rindex($self->config,'.') ) . '.fetch'
    . substr($self->config, rindex($self->config,'.') );
});

sub BUILD {
  my $self = shift;

  if($self->publisherMessageBase && $self->publisherAddress) {
    $self->setPublisher($self->publisherMessageBase, $self->publisherAddress);
  }

  $self->setLogPath($self->logPath);

  #todo: finisih ;for now we have only one level
  if ( $self->debug) { $self->setLogLevel('DEBUG'); } 
  else { $self->setLogLevel('INFO'); }
}

__PACKAGE__->meta->make_immutable;
1;
