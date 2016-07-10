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

use Seq::DBManager;
use Seq::Tracks::Build::CompletionMeta;

extends 'Seq::Tracks::Base';
# All builders need get_read_fh
with 'Seq::Role::IO';

has overwrite => (is => 'ro');
has delete => (is => 'ro');

# Anything that could be used in a thread/process isn't lazy, prevent accessor
# from being re-generated?

# Every builder needs access to the database
has db => (is => 'ro', init_arg => undef, default => sub {
  my $self = shift;
  Seq::DBManager->new({ overwrite => $self->overwrite, delete => $self->delete})
});

# Allows consumers to record track completion
has completionMeta => (
  is => 'ro',
  isa => 'Seq::Tracks::Build::CompletionMeta',
  init_arg => undef,
  default => sub { 
    my $self = shift;
    #self->overwrite specified in dbManager, which is a Role, so auto-imported
    return Seq::Tracks::Build::CompletionMeta->new( { name => $self->name,
      skip_completion_check => $self->overwrite, delete => $self->delete } );
  },
);

#Transaction size
#Consumers can choose to ignore it, and use arbitrarily large commit sizes
#this maybe moved to Tracks::Build, or enforce internally
#transactions carry overhead
#if a transaction fails/ process dies
#the database should remain intact, just the last
#$self->commitEvery records will be missing
#The larger the transaction size, the greater the db inflation
#Even compaction, using mdb_copy may not be enough to fix it it seems
#requiring a clean re-write using single transactions
#as noted here https://github.com/LMDB/lmdb/blob/mdb.master/libraries/liblmdb/lmdb.h
has commitEvery => (is => 'rw', isa => 'Int', lazy => 1, default => 1e4);

########## Arguments taken from YAML config file or passed some other way ##############
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

#if a feature value is separated by this, it has multiple values
#ex: a snp142 alleles field, separated by "," : A,T
#the default is "," because this is what UCSC specifies in the bed format
#and we only accept bed or wigfix formats
#wigfix files don't have any features, and therefore this is meaningless to them
#We could think about removing this from BUILD and making a SparseTrack base
#to avoid option overload
#could also make this private, and not allow it to change, but I don't like
#the lack of flexibility, since the goal is to help people avoid having to
#modify their input files
has multi_delim => ( is => 'ro', isa => 'Str', default => ',', lazy => 1);

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
  default => sub { {} },
);
################# General Merge Function ##################
my %haveMadeIntoArray;

# Not safe for old value, but we don't really care
sub mergeFunc {
  my ($chr, $pos, $trackKey, $oldValue, $dataToAdd);

  my $newValue = $oldValue;
  if(!$haveMadeIntoArray{$chr}{$pos}) {
    $newValue = [$oldValue];
    $haveMadeIntoArray{$chr}{$pos} = 1;
  }
  
  push @$newValue, $dataToAdd;
  return \@$newValue;
}

# some tracks may have required fields (defined by the Readme)
# For instance: SparseTracks require bed format chrom\tchromStart\tchromEnd
# We allow users to tell us what the corresponding fields are called in their files
# So that they don't have to open huge source files to edit headers
# In their config file, they specify: required_field_map : nameInHeader: <Str> requiredFieldName
# At BUIDLARGS, we make a bunch of properties based on the mappings
# As long as the consuming class defined them, they'll be used
# example:
# In config: 
#  required_field_map:
## - Chromosome : chrom
# We pass on to classes that extend this: 
#   chrom_field_name with value "Chromosome"
# @param <Str> local_files expected relative paths, relative to the files_dir
sub BUILDARGS {
  my ($class, $href) = @_;

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

  if(!$fileDir) {
    $class->log('fatal', "files_dir required for track builders");
  }

  for my $localFile (@{$href->{local_files} } ) {
    push @localFiles, path($fileDir)->child($href->{name})
      ->child($localFile)->absolute->stringify;
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
  my ($self, $feature, $dataStr) = @_;

  # Don't waste storage space on NA. In Seqant undef values equal NA (or whatever
  # Output.pm chooses to represent missing data as.
  if($dataStr =~ /NA/i) {
    return undef;
  }

  my $type = $self->noFeatureTypes ? undef : $self->getFeatureType( $feature );

  #even if we don't have a type, let's coerce anything that is split by a 
  #delimiter into an array; it's more efficient to store, and array is implied by the delim
  my @parts;
  if( ~index( $dataStr, $self->multi_delim ) ) { #bitwise compliment, return 0 only for -N
    my @vals = split( $self->multi_delim, $dataStr );

    #use defined to allow 0 valuess as types; that is a remote possibility
    #though more applicable for the name we store the thing as
    if(!defined $type) { 
      return \@vals;
    }

    # Function convert is exported by Seq::Tracks::Base
    # http://stackoverflow.com/questions/2059817/why-is-perl-foreach-variable-assignment-modifying-the-values-in-the-array
    # modifying the value here actually modifies the value in the array
    for my $val (@vals) {
      $val = $self->convert($val, $type);
    }

    # In order to allow fields to be well-indexed by ElasticSearch or other engines
    # and to normalize delimiters in the output, anything that has a comma
    # (or whatever multi_delim set to), return as an array reference
    return \@vals;
  }

  return defined $type ? $self->convert($dataStr, $type) : $dataStr;
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

__PACKAGE__->meta->make_immutable;

1;
