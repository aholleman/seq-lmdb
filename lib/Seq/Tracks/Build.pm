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

  if(ref $href->{name} eq 'HASH') {
    (undef, $href->{name}) = %{ $href->{name} }; #get the value, this is what to store as
  }

  $class->$orig($href);
};

#The role of this func is to wrap the data that each individual build method
#creates, in a consistent schema. This should match the way that Seq::Tracks::Base
#retrieves data
#use $_[0] for $self,$_[1] for $data to avoid assignemnt, 
#since this is called a ton
sub prepareData {
  #my ($self, $data) = @_;

  #Seq::Tracks::Base should know to retrieve data this way
  #this is our schema
  return {
    $_[0]->name => $_[1],
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

__PACKAGE__->meta->make_immutable;

1;
