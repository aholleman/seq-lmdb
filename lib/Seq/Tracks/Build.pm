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
use Path::Tiny qw/path/;
use Types::Path::Tiny qw/AbsDir/;
use Scalar::Util qw/looks_like_number/;
use DDP;
use File::Glob ':bsd_glob';

use Seq::DBManager;
use Seq::Tracks::Build::CompletionMeta;

extends 'Seq::Tracks::Base';
# All builders need get_read_fh
with 'Seq::Role::IO';

############### Public Exports ###################

# Anything that could be used in a thread/process isn't lazy, prevent accessor
# from being re-generated?

# Every builder needs access to the database
# Don't specify types because we do not allow consumers to set this attribute
has db => (is => 'ro', init_arg => undef, default => sub { my $self = shift;
  return Seq::DBManager->new({ overwrite => $self->overwrite, delete => $self->delete})
});

# Allows consumers to record track completion
has completionMeta => (
  is => 'ro',
  init_arg => undef,
  default => sub { my $self = shift; return Seq::Tracks::Build::CompletionMeta->new( {
    name => $self->name, skip_completion_check => $self->skip_completion_check || $self->overwrite} );
  },
);

# Transaction size. If too large (some millions, used to be 1M, DBManager may fail to execute
# If large, re-use of pages may be inefficient
# https://github.com/LMDB/lmdb/blob/mdb.master/libraries/liblmdb/lmdb.h
has commitEvery => (is => 'rw', isa => 'Int', init_arg => undef, lazy => 1, default => 1e4);

########## Arguments taken from YAML config file or passed some other way ##############

############# Required ##############
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

#called based because that's what UCSC calls it
#most things are 0 based, including anything in bed format from UCSC, fasta files
has based => ( is => 'ro', isa => 'Int', default => 0, lazy => 1, );

# DB vars; we allow these to be set, don't specify much about them because
# This package shouldn't be concerned with Seq::DBManager implementation details
has overwrite => (is => 'ro');
has delete => (is => 'ro');

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

# Configure local_files as abs path, and configure required field (*_field_name)
# *_field_name is a computed attribute that the consumer may choose to implement
# Example. In config: 
#  required_field_map:
##   chrom : Chromosome
# We pass on to classes that extend this: 
#   chrom_field_name with value "Chromosome"
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

  my @localFiles;
  my $fileDir = $href->{files_dir};

  if(!$fileDir) {
    $class->log('fatal', "files_dir required for track builders");
  }

  for my $localFile (@{$href->{local_files} } ) {
    if(path($localFile)->is_absolute) {
      push @localFiles, bsd_glob( $localFile );
      next;
    }

    push @localFiles, bsd_glob( path($fileDir)->child($href->{name})
      ->child($localFile)->absolute->stringify );
  }

  $data{local_files} = \@localFiles;

  return \%data;
};

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
}

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
sub coerceFeatureType {
  # $self == $_[0] , $feature == $_[1], $dataStr == $_[2]
  my ($self, $feature, $dataStr) = @_;

  # Don't waste storage space on NA. In Seqant undef values equal NA (or whatever
  # Output.pm chooses to represent missing data as.
  if($dataStr =~ /NA/i || $dataStr =~/^\s*$/) {
    return undef;
  }

  if($self->noFeatureTypes) {
    return $dataStr;
  }

  my $type = $self->getFeatureType( $feature );

  #even if we don't have a type, let's coerce anything that is split by a 
  #delimiter into an array; it's more efficient to store, and array is implied by the delim
  my @vals = split( $self->multi_delim, $dataStr );

  # Function convert is exported by Seq::Tracks::Base
  # http://stackoverflow.com/questions/2059817/why-is-perl-foreach-variable-assignment-modifying-the-values-in-the-array
  # modifying the value here actually modifies the value in the array
  for my $val (@vals) {
    if($val =~/^\s*$/) {
      $val = undef;
    }

    if(defined $type) {
      $val = $self->convert($val, $type);
    }
  }

  # In order to allow fields to be well-indexed by ElasticSearch or other engines
  # and to normalize delimiters in the output, anything that has a comma
  # (or whatever multi_delim set to), return as an array reference
  return @vals == 1 ? $vals[0] : \@vals;
}

state $cachedFilters;
sub passesFilter {
  if( $cachedFilters->{$_[1]} ) {
    return &{ $cachedFilters->{$_[1]} }($_[2]);
  }

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
state $cachedTransform;
#for now I only need string concatenation
state $transformOperators = ['.', 'split'];
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
