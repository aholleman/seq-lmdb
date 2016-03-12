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

use DDP;

extends 'Seq::Tracks::Base';
with 'Seq::Role::IO';
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

has remote_dir => ( is => 'ro', isa => 'Str', default => '', lazy => 1,);
has remote_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => { all_remote_files => 'elements', },
  default => sub { [] },
  lazy => 1,
);

has sql_statement => ( is => 'ro', isa => 'Str', default => '', lazy => 1, );

#called based because that's what UCSC calls it
#most things are 0 based, including anything in bed format from UCSC, fasta files
has based => ( is => 'ro', isa => 'Int', default => 0, lazy => 1, );

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

#The role of this func is to wrap the data that each individual build method
#creates, in a consistent schema. This should match the way that Seq::Tracks::Base
#retrieves data
sub prepareData {
  my ($self, $data) = @_;

  #Seq::Tracks::Base should know to retrieve data this way
  #this is our schema
  return {
    $self->name => $data,
  }
  #could also do this, but this seems more abstracted than necessary
  # $targetHref->{$pos} = {
  #   $self->name => $data,
  # }
}

#@param $chr: this is a bit of a misnomer
#it is really the name of the database
#for region databases it will be the name of track (name: )
#The role of this func is NOT to decide how to model $data;
#that's the job of the individual builder methods
# sub writeData {
#   my ($self, $chr, $pos, $data) = @_;

#   #Seq::Tracks::Base should know to retrieve data this way
#   #this is our schema
#   $self->dbPatch($chr, $pos, {$self->name => $data} );
# }

#@param $posHref : {positionKey : data}
#the positionKey doesn't have to be numerical;
#for instance a gene track may use its gene name

#NOT safe for the input data
# sub writeAllData {
#   #overwrite not currently used
#   my ($self, $chr, $posHref, $overwrite) = @_;

#   if(ref $posHref eq 'ARRAY') {
#     goto &writeAllDataArray;
#   }

#  # save memory, mutate
#   for my $pos (%$posHref) {
#     $posHref->{$pos} = {
#       $self->name => $posHref->{$pos}
#     };
#     # say "had we been writing, we would have written a record at $chr : $pos that looks like";
#     # p $posHref->{$pos};
#   }
  
#   $self->dbPatchBulk($chr, $posHref);
# }

# #not safe for the input data
# #expects that every position in a database has a corresponding
# #idx in posAref
# sub writeAllDataArray {
#   my ($self, $chr, $posAref) = @_;

#   # save memory, mutate
#   my $idx = 0;
#   for my $data (@$posAref) {
#     $posAref->[$idx] = {
#       $self->name => $data,
#     };
#     $idx++;
#   }

#   $self->dbPatchBulkArray($chr, $posAref);
# }


# sub prepareAllData {
#   #overwrite not currently used
#   my ($self, $chr, $posHref) = @_;

#   if(ref $posHref eq 'ARRAY') {
#     goto &prepareAllDataArray;
#   }

#  # save memory, mutate
#   for my $pos (keys %$posHref) {
#     $posHref->{$pos} = {
#       $self->name => {
#         $self->typeKey => $self->type,
#         $self->dataKey => $posHref->{$pos},
#       }
#     };
#     # say "had we been writing, we would have written a record at $chr : $pos that looks like";
#     # p $posHref->{$pos};
#   }
# }

# sub prepareAllDataArray {
#   #overwrite not currently used
#   my ($self, $chr, $posAref) = @_;

#   if(ref $posHref eq 'HASH') {
#     goto &prepareAllData;
#   }

#   my $idx = 0;
#   for my $data (@$posAref) {
#     $posAref->[$idx] = {
#       $self->name => {
#         $self->typeKey => $self->type,
#         $self->dataKey => $data,
#       }
#     };
#     $idx++;
#   }
# }

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