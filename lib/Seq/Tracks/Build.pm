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

extends 'Seq::Tracks::Base';
with 'Seq::Role::IO'; #all build methods need to read files

#anything with an underscore comes from the config format
#anything config keys that can be set in YAML but that only need to be used
#during building should be defined here
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

#if a feature value is separated by this, it has multiple values
#ex: a snp142 alleles field, separated by "," : A,T
#the default is "," because this is what UCSC specifies in the bed format
#and we only accept bed or wigfix formats
#wigfix files don't have any features, and therefore this is meaningless to them
#We could think about removing this from BUILD and making a BedTrack.pm base
#to avoid option overload
#could also make this private, and not allow it to change, but I don't like
#the lack of flexibility, since the goal is to help people avoid having to
#modify their input files
has multi_delim => ( is => 'ro', isa => 'Str', default => ',', lazy => 1, );

#some tracks, like reference & score won't have this, so we lazy initialize
#(and memoize as a result)

#local files are given as relative paths, relative to the files_dir
around BUILDARGS => sub {
  my ($orig, $class, $href) = @_;

  say "in buildargs in build.pm";
  my @localFiles;
  my $fileDir = $href->{files_dir};

  for my $localFile (@{$href->{local_files} } ) {
    push @localFiles, path($fileDir)->child($href->{type} )
      ->child($localFile)->absolute->stringify;
  }

  $href->{local_files} = \@localFiles;

  return $class->$orig($href);
};

#The role of this func is to wrap the data that each individual build method
#creates, in a consistent schema. This should match the way that Seq::Tracks::Base
#retrieves data
#use $_[0] for $self,$_[1] for $data to avoid assignemnt, 
#since this is called a ton
sub prepareData {
  #my ($self, $data) = @_;
  #so $_[0] is $self, $_[0] is $data

  #Seq::Tracks::Base should know to retrieve data this way
  #this is our schema
  #the dbName is an internally generated integer, that we use instead of 
  #the feature name specified by the user, to save space
  return {
    $_[0]->dbName => $_[1],
  }
  #could also do this, but this seems more abstracted than necessary
  # $targetHref->{$pos} = {
  #   $self->name => $data,
  # }
}

#type conversion; try to limit performance impact by avoiding unnec assignments
#@params {String} $_[1] : feature the user wants to check
#@params {String} $_[2] : data for that feature
#@returns {String} : coerced type

#We always return an array for anything split by multi-delim; arrays are implied by those
#arrays are also more space efficient in msgpack
#This is stored in Build.pm because this only needs to happen during insertion into db
sub coerceFeatureType {
  # $self == $_[0] , $feature == $_[1], $dataStr == $_[2]
  # my ($self, $dataStr) = @_;

  my $type = $_[0]->noFeatureTypes ? undef : $_[0]->getFeatureType( $_[1] );

  #even if we don't have a type, let's coerce anything that is split by a 
  #delimiter into an array; it's more efficient to store, and array is implied by the delim
  my @parts;
  if( ~index( $_[2], $_[0]->multi_delim ) ) { #bitwise compliment, return 0 only for -N
    my @vals = split( $_[0]->multi_delim, $_[2] );

    #use defined to allow 0 values as types; that is a remote possibility
    #though more applicable for the name we store the thing as
    if(!defined $type) { 
      return \@vals;
    }

    #http://stackoverflow.com/questions/2059817/why-is-perl-foreach-variable-assignment-modifying-the-values-in-the-array
    #modifying the value here actually modifies the value in the array
    for my $val (@vals) {
      $val = $_[0]->convert($val, $type);
    }

    #In order to save space in the db, and since may need to use the values
    #anything that has a comma is just returned as an array ref
    return \@vals;
  }

  if(!defined $type) {
    return $_[2];
  }

  return $_[0]->convert($_[2], $type);
}

#Not currently used; I find it simpler to read to just subtract $self->based
#where that is needed, and that also saves sub call overhead
#takes a potentially non-0 based thing, makes it 0 based
#called via $self->toZeroBased;
#@param $_[1] == the base  . This is the only argument: $self->zeroBased($base) 
#@param $_[0] == $self : class instance;
#this can be called billions of times, so trying to reduce performance overhead
#of assignment
# sub zeroBased {
#   if ( $_[0]->based == 0 ) { return $_[1]; }
#   return $_[1] - $_[0]->based;
# }

__PACKAGE__->meta->make_immutable;

1;
