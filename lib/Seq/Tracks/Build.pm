use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Build;

our $VERSION = '0.001';

# ABSTRACT: A base class for Tracks::*:BUILD classes
# VERSION

#TODO: BEFORE BUILDING ANY DATABASE, CHECK THAT THE REFERENCE HAS BEEN MADE

use Moose 2;
use namespace::autoclean;
use Path::Tiny qw/path/;
use DDP;

use MooseX::Types::Path::Tiny qw/AbsDir/;
use Scalar::Util qw/looks_like_number/;

use MCE::Loop;

extends 'Seq::Tracks::Base';
with 'Seq::Role::IO'; #all build methods need to read files

#anything with an underscore comes from the config format
#anything config keys that can be set in YAML but that only need to be used
#during building should be defined here
has genome_chrs => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    allWantedChrs => 'keys',
    chrIsWanted => 'defined', #hash over array because unwieldy firstidx
  },
  required => 1,
);

has wantedChr => (
  is => 'ro',
  isa => 'Maybe[Str]',
  lazy => 1,
  default => undef,
);

has files_dir => ( is => 'ro', isa => AbsDir, coerce => 1 );

has local_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => {
    allLocalFiles => 'elements',
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

# name => 'command'
has build_row_filters => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    hasFilter => 'exists',
    allFieldsToFilterOn => 'keys',
  },
  lazy => 1,
  required => 0,
  default => sub { {} },
);

has build_field_transformations => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    hasTransform => 'exists',
    allFieldsToTransform => 'keys',
  },
  lazy => 1,
  required => 0,
  default => sub { {} },
);

# some tracks may have required fields
# we allow users to map these to whatever the equivalent field is called
# in their file, so that they don't have to open huge source files to edit headers
#this config field is called required_field_map
#we don't actually need to instantiate it as a property
#instead, around BUIDLARGS, we will make a bunch of properties based
#on the mappings
#as long as the consuming class defined them, they'll be used
#example:
#required_field_map:
## - source_file_name : we_require_name
## - Chromosome : chrom
##
##this will result in a Moose attribute called chrom_field_name
#local files are given as relative paths, relative to the files_dir
around BUILDARGS => sub {
  my ($orig, $class, $href) = @_;

  my %data = %$href;
  
  #First map required_field_mappings to required_field
  if(defined $data{required_fields_map} ) {
    if(ref $data{required_fields_map} ne 'ARRAY') {
      $class->log('fatal','required_field_map must be an array (Ex: -name: required_name )');
    }
    for my $nameHref (@{ $data{required_fields_map} } ){
      if(ref $nameHref ne 'HASH') {
        $class->log('fatal', 'Each entry of required_field_map must be a name: required_name pair');
      }
      my ($mapped_name, $required_name) = %$nameHref;
      $data{$required_name . "_field_name"} = $mapped_name;
    }
  }

  my @localFiles;
  my $fileDir = $href->{files_dir};

  for my $localFile (@{$href->{local_files} } ) {
    push @localFiles, path($fileDir)->child($href->{type} )
      ->child($localFile)->absolute->stringify;
  }

  $data{local_files} = \@localFiles;


  if(defined $data{genome_chrs} &&  ref $data{genome_chrs} eq 'ARRAY') {
    my %genome_chrs = map { $_ => 1 } @{$data{genome_chrs} };
    $data{genome_chrs} = \%genome_chrs;
  }

  if(defined $data{wantedChr} ) {
    if (exists $data{genome_chrs}->{$data{wantedChr} } ) {
      $data{genome_chrs} = {
        $data{wantedChr} => 1,
      };
    } else {
      die 'Wanted chromosome not listed in genome_chrs in YAML config';
    }
  }
  return $class->$orig(\%data);
};

sub BUILD {
  my $self = shift;

  my @allLocalFiles = $self->allLocalFiles;
  my @allWantedChrs = $self->allWantedChrs;

  if(@allWantedChrs > @allLocalFiles && @allLocalFiles > 1) {
    $self->log("warn", "You're specified " . scalar @allLocalFiles . " file for " . $self->name . ", but "
      . scalar @allWantedChrs . " chromosomes. We will assume there is only one chromosome per file, "
      . "and that one chromosome isn't accounted for.");
  }
}
###################Prepare Data For Database Insertion ##########################
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
}

sub deleteTrack {
  my $self = shift;

  MCE::Loop->init({
    max_workers => 26,
    chunk_size => 1,
  });

  my @err= mce_loop {
    my $err = $self->dbDeleteKeys($_. $self->dbName);

    if($err) {
      MCE->gather($err);
    }
  } $self->allWantedChrs;

  return @err;
}

#########################Type Conversion, Input Field Filtering #########################
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

state $cachedFilters;
sub passesFilter {
  if( $cachedFilters->{$_[1]} ) {
    return &{ $cachedFilters->{$_[1]} }($_[2]);
  }

  #   $_[0],      $_[1],    $_[2]
  my ($self, $featureName, $featureValue) = @_;

  my $command = $self->build_row_filters->{$featureName};

  my ($infix, $value) = split(' ', $command);

  if ($infix eq '==') {
    if(looks_like_number($value) ) {
      $cachedFilters->{$featureName} = sub {
        my $fieldValue = shift;
        
        return $fieldValue == $value; 
      } 
    } else {
      $cachedFilters->{$featureName} = sub {
        my $fieldValue = shift;
        
        return $fieldValue eq $value; 
      }
    }
    
  } elsif($infix eq '>') {
    $cachedFilters->{$featureName} = sub {
      my $fieldValue = shift;
      return $fieldValue > $value;
    }
  } elsif($infix eq '>=') {
    $cachedFilters->{$featureName} = sub {
      my $fieldValue = shift;
      return $fieldValue >= $value;
    }
  } elsif ($infix eq '<') {
    $cachedFilters->{$featureName} = sub {
      my $fieldValue = shift;
      return $fieldValue < $value;
    }
  } elsif ($infix eq '<=') {
    $cachedFilters->{$featureName} = sub {
      my $fieldValue = shift;
      return $fieldValue <= $value;
    }
  } else {
    $self->log('warn', "This filter, ".  $self->build_row_filters->{$featureName} . 
      ", uses an  operator $infix that isn\'t supported.
      Therefore this filter won\'t be run, and all values for $featureName will be allowed");
    #allow all
    $cachedFilters->{$featureName} = sub { return 1; };
  }

  return &{ $cachedFilters->{$featureName} }($featureValue);
}

state $cachedTransform;
#for now I only need string concatenation
state $transformOperators = ['.',];
sub transformField {
  if( defined $cachedTransform->{$_[1]} ) {
    return &{ $cachedTransform->{$_[1]} }($_[2]);
  }
  #   $_[0],      $_[1],    $_[2]
  my ($self, $featureName, $featureValue) = @_;

  my $command = $self->build_field_transformations->{$featureName};

  my ($leftHand, $rightHand) = split(' ', $command);

  my $codeRef;

  if($self->_isTransformOperator($leftHand) ) {
    if($leftHand eq '.') {
      $codeRef = sub {
        # my $fieldValue = shift;
        # same as $_[0];

        return $_[0] . $rightHand;
      }
    }
  } elsif($self->_isTransformOperator($rightHand) ) {
    if($rightHand eq '.') {
      $codeRef = sub {
       # my $fieldValue = shift;
       # same as $_[0];
        return $leftHand . $_[0];
      }
    }
  }

  if(!defined $codeRef) {
    $self->log('warn', "Requested transformation, $command, for $featureName, not understood");
    return $featureValue;
  }
  
  $cachedTransform->{$featureName} = $codeRef;

  return &{$codeRef}($featureValue);
}

sub _isTransformOperator {
  my ($self, $value) = @_;

  for my $operator (@$transformOperators) {
    if(index($value, $operator) > -1 ) {
      return 1;
    }
  }
  return 0;
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
