use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Build;

our $VERSION = '0.001';

# ABSTRACT: A base class for track classes
# VERSION

use Moose 2;
use namespace::autoclean;
use MooseX::Types::Path::Tiny qw/AbsPath/;

#this only is used by Build
has local_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  lazy    => 1,
  handles => {
    all_local_files => 'elements',
  },
  default => sub { [] },
);

has remote_dir => ( is => 'ro', isa => 'Str', lazy => 1, default => '');
has remote_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => { all_remote_files => 'elements', },
  lazy => 1,
  default => sub { [] },
);

has sql_statement => ( is => 'ro', isa => 'Str', lazy => 1, default => '');

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