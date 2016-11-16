use 5.10.0;
use strict;
use warnings;

package Seq::Build;
use lib './lib';
our $VERSION = '0.001';

use DDP;
# ABSTRACT: A class for building all files associated with a genome assembly
# VERSION

=head1 DESCRIPTION

  @class Seq::Build
  Iterates all of the builders present in the config file
  And executes their buildTrack method
  Also guarantees that the reference track will be built first

  @example

=cut

use Mouse 2;
use namespace::autoclean;
extends 'Seq::Base';

use Seq::Tracks;
use Seq::Tracks::Base::Types;
use Utils::Base;
use List::Util qw/first/;
use YAML::XS qw/LoadFile Dump/;
use Time::localtime;

has wantedType => (is => 'ro', isa => 'Maybe[Str]', lazy => 1, default => undef);

#TODO: allow building just one track, identified by name
has wantedName => (is => 'ro', isa => 'Maybe[Str]', lazy => 1, default => undef);

# Tracks configuration hash
has tracks => (is => 'ro', required => 1);

has meta_only => (is => 'ro', default => 0);

# The config file path
has config => (is => 'ro', required => 1);

#Figures out what track type was asked for 
#and then builds that track by calling the tracks 
#"buildTrack" method
sub BUILD {
  my $self = shift;

  my $tracks = Seq::Tracks->new({tracks => $self->tracks});

  my $buildDate = Utils::Base::getDate();
  # Meta tracks are built during instantiation, so if we only want to build the
  # meta data, we can return here safely.
  if($self->meta_only) {
    return;
  }
  
  my @builders;
  my @allBuilders = $tracks->allTrackBuilders;

  if($self->wantedType) {
    my @types = split(/,/, $self->wantedType);
    
    for my $type (@types) {
      my $buildersOfType = $tracks->getTrackBuildersByType($type);

      if(!defined $buildersOfType) {
        $self->log('fatal', "Track type \"$type\" not recognized");
        return;
      }
      
      push @builders, @$buildersOfType;
    }
  } elsif($self->wantedName) {
    my @names = split(/,/, $self->wantedName);
    
    for my $name (@names) {
      my $builderOfName = $tracks->getTrackBuilderByName($name);

      if(!defined $builderOfName) {
        $self->log('fatal', "Track name \"$name\" not recognized");
        return;
      }

      push @builders, $builderOfName;
    }
  } else {
    @builders = @allBuilders;

    #If we're building all tracks, reference should be first
    if($builders[0]->name ne $tracks->getRefTrackBuilder()->name) {
      $self->log('fatal', "Reference track should be listed first");
    }
  }

  #TODO: return error codes from the rest of the buildTrack methods
  my $decodedConfig = LoadFile($self->config);

  for my $builder (@builders) {
    $self->log('info', "Started building " . $builder->name );
    
    #TODO: implement errors for all tracks
    my ($exitStatus, $errMsg) = $builder->buildTrack();
    
    if(!defined $exitStatus || $exitStatus != 0) {
      $self->log('warn', "Failed to build " . $builder->name);
    }

    my $track = first{$_->{name} eq $builder->name} @{$decodedConfig->{tracks}};

    $track->{build_date} = $buildDate;
    $track->{version} = $track->{version} ? ++$track->{version} : 1;
    
    $self->log('info', "Finished building " . $builder->name );
  }

  $self->log('info', "finished building all requested tracks: " 
    . join(", ", map{ $_->name } @builders) );

  $decodedConfig->{build_date} = $buildDate;
  $decodedConfig->{version} = $decodedConfig->{version} ? ++$decodedConfig->{version} : 1;

  # If this is already a symlink, remove it
  if(-l $self->config) {
    unlink $self->config;
  } else {
    my $backupPath = $self->config . ".build-bak.$buildDate";
    if( system ("rm -f $backupPath; mv " . $self->config . " " . $self->config . ".build-bak.$buildDate" ) != 0 ) {
      $self->log('fatal', "Failed to back up " . $self->config);
    }
  }

  my $newConfigPath = $self->config . ".build.$buildDate";
  open(my $fh, '>', $newConfigPath) or $self->log('fatal', "Couldn't open $newConfigPath for writing" );

  say $fh Dump($decodedConfig);

  # -f forces hard link / overwrite
  if( system ("ln -f " . $newConfigPath . " " . $self->config) != 0 ) {
    $self->log('fatal', "Failed to hard link " . $self->config . " to " . $newConfigPath);
  }
}

__PACKAGE__->meta->make_immutable;

1;
