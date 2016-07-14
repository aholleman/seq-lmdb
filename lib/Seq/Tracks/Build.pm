use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Build;

our $VERSION = '0.001';

# ABSTRACT: A base class for Tracks::*:BUILD classes
# VERSION

use Mouse 2;
use MouseX::NativeTraits;
use namespace::autoclean;
use Scalar::Util qw/looks_like_number/;
use DDP;

use Seq::DBManager;
use Seq::Tracks::Build::CompletionMeta;
use Seq::Tracks::Base::Types;
use Seq::Tracks::Build::LocalFilesPaths;

extends 'Seq::Tracks::Base';
# All builders need get_read_fh
with 'Seq::Role::IO';
#################### Instance Variables #######################################
############################# Public Exports ##################################
# DB vars; we allow these to be set, don't specify much about them because
# This package shouldn't be concerned with Seq::DBManager implementation details
has overwrite => (is => 'ro', lazy => 1, default => 0);
has delete => (is => 'ro', lazy => 1, default => 0);

# Every builder needs access to the database
# Don't specify types because we do not allow consumers to set this attribute
has db => (is => 'ro', init_arg => undef, default => sub { my $self = shift;
  return Seq::DBManager->new({ overwrite => $self->overwrite, delete => $self->delete})
});

# Allows consumers to record track completion, skipping chromosomes that have 
# already been built
has completionMeta => (is => 'ro', init_arg => undef, default => sub { my $self = shift;
  return Seq::Tracks::Build::CompletionMeta->new({name => $self->name, db => $self->db});
});

# Transaction size. If large, re-use of pages may be inefficient
# https://github.com/LMDB/lmdb/blob/mdb.master/libraries/liblmdb/lmdb.h
has commitEvery => (is => 'rw', isa => 'Int', init_arg => undef, lazy => 1, default => 1e4);

# All tracks want to know whether we have 1 chromosome per file or not
has chrPerFile => (is => 'ro', init_arg => undef, writer => '_setChrPerFile');

########## Arguments taken from YAML config file or passed some other way ##############

#################################### Required ###################################
has local_files => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => {
    noLocalFiles => 'is_empty',
    allLocalFiles => 'elements',
  },
  required => 1,
);

########################### Optional arguments ################################
#called based because that's what UCSC calls it
#most things are 0 based, including anything in bed format from UCSC, fasta files
has based => ( is => 'ro', isa => 'Int', default => 0, lazy => 1);

# The delimiter used in coercion commands
has multi_delim => ( is => 'ro', lazy => 1, default => sub{qr/[,;]/});

# If a row has a field that doesn't pass this filter, skip it
has build_row_filters => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    hasFilter => 'exists',
    allFieldsToFilterOn => 'keys',
  },
  lazy => 1,
  default => sub { {} },
);

# Transform a field in some way
has build_field_transformations => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    hasTransform => 'exists',
    allFieldsToTransform => 'keys',
  },
  lazy => 1,
  default => sub { {} },
);

################################ Constructor ################################
sub BUILD {
  my $self = shift;

  my @allLocalFiles = $self->allLocalFiles;

  #exported by Seq::Tracks::Base
  my @allWantedChrs = $self->allWantedChrs;

  if(@allWantedChrs > @allLocalFiles && @allLocalFiles > 1) {
    $self->log("warn", "You're specified " . scalar @allLocalFiles . " file for "
      . $self->name . ", but " . scalar @allWantedChrs . " chromosomes. We will "
      . "assume there is only one chromosome per file, and that 1 chromosome isn't accounted for.");
  }

  $self->_setChrPerFile(@allLocalFiles > 1 ? 1 : 0);
}

# Configure local_files as abs path, and configure required field (*_field_name)
# *_field_name is a computed attribute that the consumer may choose to implement
# Example. In config: 
#  required_field_map:
##   chrom : Chromosome
# We pass on to classes that extend this: 
#   chrom_field_name with value "Chromosome"
my $localFilesHandler = Seq::Tracks::Build::LocalFilesPaths->new();
sub BUILDARGS {
  my ($class, $href) = @_;

  my %data = %$href;
  #First map required_field_mappings to required_field
  if(defined $data{required_fields_map} ) {
    if(ref $data{required_fields_map} ne 'HASH') {
      $class->log('fatal','required_field_map must be an array (Ex: name: required_name )');
    }

    for my $requiredField (keys %{ $data{required_fields_map} } ){
      $data{$requiredField . "_field_name"} = $data{required_fields_map}{$requiredField};
    }
  }

  if(!$href->{files_dir}) {
    $class->log('fatal', "files_dir required for track builders");
  }

  $data{local_files} = $localFilesHandler->makeAbsolutePaths($href->{files_dir},
    $href->{name}, $href->{local_files});

  return \%data;
};

###################Prepare Data For Database Insertion ##########################
# prepareData should be used by any track that is inseting data into the main database
# Soft-enforcement of a schema
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

#########################Type Conversion, Input Field Filtering #########################
#type conversion; try to limit performance impact by avoiding unnec assignments
#@params {String} $_[1] : feature the user wants to check
#@params {String} $_[2] : data for that feature
#@returns {String} : coerced type

# This is stored in Build.pm because this only needs to happen during insertion into db
state $converter = Seq::Tracks::Base::Types->new();
sub coerceFeatureType {
  # $self == $_[0] , $feature == $_[1], $dataStr == $_[2]
  my ($self, $feature, $dataStr) = @_;

  # Don't waste storage space on NA. In Seqant undef values equal NA (or whatever
  # Output.pm chooses to represent missing data as.
  if($dataStr =~ /NA/i || $dataStr =~/^\s*$/) {
    return undef;
  }

  # Don't mutate the input if no type is stated for the feature
  if($self->noFeatureTypes) {
    return $dataStr;
  }

  my $type = $self->getFeatureType( $feature );

  # If the type is part of a list, we need to grab individual values
  my @vals = split( $self->multi_delim, $dataStr );

  # modifying the value here actually modifies the value in the array
  # http://stackoverflow.com/questions/2059817/why-is-perl-foreach-variable-assignment-modifying-the-values-in-the-array
  for my $val (@vals) {
    if($val =~/^\s*$/) {
      $val = undef;
    }

    if(defined $type) {
      $val = $converter->convert($val, $type);
    }
  }

  # In order to allow fields to be well-indexed by ElasticSearch or other engines
  # and to normalize delimiters in the output, anything that has a comma
  # (or whatever multi_delim set to), return as an array reference
  return @vals == 1 ? $vals[0] : \@vals;
}

sub passesFilter {
  state $cachedFilters;

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

######################### Field Transformations ###########################
#for now I only need string concatenation
state $transformOperators = ['.', 'split'];
sub transformField {
  state $cachedTransform;
  
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

    if($leftHand eq 'split') {
      $codeRef = sub {
        # my $fieldValue = shift;
        # same as $_[0];
        my @data = split(/$rightHand/, $_[0]);
        return @data == 1 ? $data[0] : \@data;
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

__PACKAGE__->meta->make_immutable;

1;
