use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Get;
# Synopsis: For fetching data
# TODO: make this a role?
our $VERSION = '0.001';

use Moose 2;
extends 'Seq::Tracks::Base';


# Needed in order to go from the database name to the label the user wants to see
# dbName => featureNameAsItAppearsInInputFile
has _invertedFeatures => (
  is => 'ro',
  isa => 'HashRef[Str]',
  lazy => 1,
  traits => ['Hash'],
  handles  => {
    invertedFeatureNamesKv => 'kv',
  },
  _builder => '_buildInvertedFeatures',
);

sub _buildInvertedFeatures {
  my $self = shift;

  if($self->noFeatures) {
    return {};
  }
  
  my %invertedIdx;
  for my $pair ($self->featureNamesKv) {
    # my $name = $pair->[0]; aka -feature: name
    # my $storedAs = $pair->[1]; aka dbName
    $invertedIdx{ $pair->[1] } = $pair->[0];
  }
  return \%invertedIdx;
}

# has _invertedRequiredFields => (
#   is => 'ro',
#   isa => 'HashRef[Str]',
#   lazy => 1,
#   traits => ['Hash'],
#   handles  => {
#     getFeatureName => 'get',
#     allFeatureDbNames => 'keys',
#     invertedFeatureNamesKv => 'kv',
#   },
#   _builder => '_buildInvertedFeatures',
# );

# sub _buildInvertedFeatures {
#   my $self = shift;

#   if($self->noFeatures) {
#     return {};
#   }
  
#   my %invertedIdx;
#   for my $pair ($self->featureNamesKv) {
#     # my $name = $pair->[0]; aka -feature: name
#     # my $storedAs = $pair->[1]; aka dbName
#     $invertedIdx{ $pair->[1] } = $pair->[0];
#   }
#   return \%invertedIdx;
# }

#The only track that needs to modify this function is RegionTrack
#They're fundamentally different in that they have a 2nd database that 
#they need to query for items held in the main database
#TODO:In regiontrack overload this function
#Doesn't shift anything to save performance, can be called tens of millions of times
sub get {
  #$href is the data that the user previously grabbed from the database
  my ($self, $href) = @_;
  # so $_[0] is $self, $_[1] is $href; 

  #this won't work well for Region tracks, so those should override this method
  #internally the feature data is store keyed on the dbName not name, to save space
  # 'some dbName' => someData
  #If the value is not a ref, we assume it's the only value available for that feature
  #so we could also just check whether there's a ref; not sure which is faster
  # if($_[0]->noFeatures) {
  #   return $_[1]->{ $_[0]->dbName };
  # }
  #this feels like the most Go-like, and direct means
  #reads: if (!ref $href->{$self->dbName} ) { return $href->{$self->dbName} }

  #dbName is simply the database version of the feature name
  #we do this to save space in the database, by a huge number of bytes
  #and protects against users using really funky long feature names
  #dbName defined in Seq::Tracks::Base

  #as stated above some features simply don't have any features, just a scalar
  #like scores
  if(!ref $href->{ $self->dbName } ) {
    return $href->{ $self->dbName };
  }

  #we have features, so let's grab only those; user can change after they build
  #to reduce how much is put into the output file
  if(ref $href->{ $self->dbName } ne 'HASH') {
    return $self->log('error', "Expected data to be HASH reference, got " 
      . ref $href->{ $self->dbName } );
  }

  my %out;

  #now go from the database feature names to the human readable feature names
  #and include only the featuers specified in the yaml file
  #each $pair <ArrayRef> : [dbName, humanReadableName]
  for my $pair ($self->invertedFeatureNamesKv) {
    #First, we want to get the 
    #reads: $href->{$self->dbName}{ $pair->[0] } where $pair->[0] == feature dbName
    my $val = $href->{ $self->dbName }{ $pair->[0] }; 
    if ($val) {
      #pair->[1] == feature name (what the user specified as -feature: name
      $out{ $pair->[1] } = $val;
    }
  }
  return \%out;
}

# use the existing method to munge stuff here
# sub toString {
#   my $self = shift; 
# }

__PACKAGE__->meta->make_immutable;

1;