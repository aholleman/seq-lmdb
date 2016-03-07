use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Build;

our $VERSION = '0.001';

# ABSTRACT: A base class for track classes
# VERSION

use Moose 2;
use namespace::autoclean;
use Path::Tiny qw/path/;
use List::Util::XS; #qw/first/ doesn't work

use DDP;

extends 'Seq::Tracks::Base';

# this should move to some overall package, that is a singleton
# maybe assembly should be moved to a role
has debug => (
  is => 'ro',
  isa => 'Int',
  lazy => 1,
  default => 1,
);

# this should move to some overall package, that is a singleton
# maybe assembly should be moved to a role
# as should anything that is set once for the entire config
# and should be shared between all types
has genome_chrs => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  handles => {
    'allWantedChrs' => 'elements',
  },
  lazy_build => 1,
);

#anything with an underscore comes from the config format
#this only is used by Build
has local_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => {
    all_local_files => 'elements',
  },
  default => sub { [] },
  lazy    => 1,
);

has remote_dir => ( is => 'ro', isa => 'Str', lazy => 1, default => '');
has remote_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => { all_remote_files => 'elements', },
  default => sub { [] },
  lazy => 1,
);

has sql_statement => ( is => 'ro', isa => 'Str', default => '', lazy => 1,);

#local files are given as relative paths, relative to the files_dir
around BUILDARGS => sub {
  my $orig = shift;
  my $class = shift;
  my $href = shift;

  my @localFiles;
  my $fileDir = $href->{files_dir};

  for my $localFile (@{$href->{local_files} } ) {
    push @localFiles, path($fileDir)->child($href->{type} )->child($localFile)->absolute->stringify;
  }

  if(@localFiles) {
    $href->{local_files} = \@localFiles;
  }

  $class->$orig($href);
};

sub BUILD {
  my $self = shift;

  $self->read_only(0);
}

sub chrIsWanted {
  my ($self, $chr) = @_;

  #using internal methods, public API for public use (regarding wantedChrs)
  return List::Util::first { $_ eq $chr } @{$self->genome_chrs };
}

#The role of this func is to wrap the data that each individual build method
#creates, in a consistent schema. This should match the way that Seq::Tracks::Base
#retrieves data
#@param $chr: this is a bit of a misnomer
#it is really the name of the database
#for region databases it will be the name of track (name: )
#The role of this func is NOT to decide how to model $data;
#that's the job of the individual builder methods
sub writeData {
  my ($self, $chr, $pos, $data) = @_;

  #Seq::Tracks::Base should know to retrieve data this way
  #this is our schema
  my %out = (
    $self->name => {
      $self->typeKey => $self->type,
      $self->dataKey => $data,
    }
  );

  $self->dbPatch($chr, $pos, \%out);
}

#@param $posHref : {positionKey : data}
#the positionKey doesn't have to be numerical;
#for instance a gene track may use its gene name

#NOT safe for the input data
sub writeAllData {
  #overwrite not currently used
  my ($self, $chr, $posHref) = @_;

  if(ref $posHref eq 'ARRAY') {
    goto &writeAllDataArray;
  }

 # save memory, mutate
  for my $key (keys %$posHref) {
    $posHref->{$key} = {
      $self->name => {
        $self->typeKey => $self->type,
        $self->dataKey => $posHref->{$key},
      }
    }
  }

  $self->dbPatchBulk($chr, $posHref);
}

#not safe for the input data
sub writeAllDataArray {
  my ($self, $chr, $posAref) = @_;

  # save memory, mutate
  my $idx = 0;
  for my $data (@$posAref) {
    $posAref->[$idx] = {
      $self->name => {
        $self->typeKey => $self->type,
        $self->dataKey => $data,
      }
    };
    $idx++;
  }

  $self->dbPatchBulkArray($chr, $posAref);
}

__PACKAGE__->meta->make_immutable;

1;

# sub updateAllFeaturesData {
#   #overwrite not currently used
#   my ($self, $chr, $pos, $dataHref, $overwrite) = @_;

#   if(!defined $dataHref->{$self->name} 
#   || $dataHref->{$self->name}{type} eq $self->type ) {
#     $self->tee_logger('warn', 'updateAllFeaturesData requires 
#       data of the same type as the calling track object');
#     return;
#   }

#   goto &writeAllFeaturesData;
# }