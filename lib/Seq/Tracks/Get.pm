use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Get;
# Synopsis: For fetching data
# TODO: make this a role?
our $VERSION = '0.001';

use Moose 2;

extends 'Seq::Tracks::Base';
with 'Seq::Tracks::Headers';

sub BUILD {
  my $self = shift;
  #once feature exclusion is ready 
  # my @includedFeatures;

  # for my $feature ($self->allFeatureNames) {
  #   if(!first{ $_ eq $feature } @{$self->annotation_exclude_features} ) {
  #     push @includedFeatures, $feature;
  #   }
  # } 
  # $self->addFeaturesToTrackHeaders(\@includedFeatures $self->name);

  #register all features for this track
  #@params $parent, $child
  $self->addFeaturesToTrackHeaders([$self->allFeatureNames], $self->name);;
}
#The only track that needs to modify this function is RegionTrack
#They're fundamentally different in that they have a 2nd database that 
#they need to query for items held in the main database
#TODO:In regiontrack overload this function
#Doesn't shift anything to save performance, can be called tens of millions of times
sub get {
  #$href is the data that the user previously grabbed from the database
  #my ($self, $href) = @_;
  # so $_[0] is $self, $_[1] is $href; 

  if(ref $_[1] eq 'ARRAY') {
    goto &getBulk;
  }
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

  if(!exists $_[1]->{ $_[0]->dbName } ) {
    #interestingly, perl may complain in map { $_ => $_->get($dataHref) } @tracks
    #if this is not done explicitly
    return undef;
  }

  #as stated above some features simply don't have any features, just a scalar
  #like scores
  #on the other hand, sometimes we just want all features returned if the user
  #doesn't specify. this takes care of both cases : return whatever we have
  if($_[0]->noFeatures) {
    return $_[1]->{$_[0]->dbName};
  }

  #we have features, so let's grab only those; user can change after they build
  #to reduce how much is put into the output file
  # if(ref $href->{ $self->dbName } ne 'HASH') {
  #   return $self->log('error', "Expected data to be HASH reference, got " 
  #     . ref $href->{ $self->dbName } );
  # }

  #now go from the database feature names to the human readable feature names
  #and include only the featuers specified in the yaml file
  #each $pair <ArrayRef> : [dbName, humanReadableName]
  #and if we can't find the feature, it's ok, leave as undefined
  
  #my %out;
  # for my $name ($self->allFeatureNames) {
  #   #First, we want to get the 
  #   $out{ $name } = $href->{ $self->dbName }{ $self->getFieldDbName($name) };
  # }
  # return \%out;

  #this is equivalent to the commented out code above
  return {
    map { $_ => $_[1]->{ $_[0]->dbName }{ $_[0]->getFieldDbName($_) } } $_[0]->allFeatureNames 
  }
}

sub getBulk {
  #my ($self, $aRefOfDataHrefs) = @_;
  # $self == $_[0] ; $aRefOfDataHrefs == $_[1]
  if(ref $_[1] eq 'HASH') {
    goto &get;
  }

  #http://www.perlmonks.org/?node_id=596282
  return [ map { $_[0]->get($_) } @{ $_[1] } ];
}
# use the existing method to munge stuff here
# sub toString {
#   my $self = shift; 
# }

__PACKAGE__->meta->make_immutable;

1;

#TODO: figure out how to neatly add feature exclusion
# has annotation_exclude_features => (
#   is => 'ro',
#   isa => 'ArrayRef',
#   lazy => 1,
#   default => sub { [] },
# );

# my @featureLabels;
#   my @exludedFeatures = defined $data{annotation_exclude_features} 
#     ? @{$data{annotation_exclude_features} } : ();

#   for my $feature (@{$data{features} } ) {
#     if (ref $feature eq 'HASH') {
#       my ($name, $type) = %$feature; #Thomas Wingo method

#       if(@exludedFeatures && first { $_ eq $name } @exludedFeatures ) {
#         next;
#       }
#       push @featureLabels, $name;
#       $data{_featureDataTypes}{$name} = $type;

#       next;
#     }

#     if(@exludedFeatures && first { $_ eq $feature } @exludedFeatures ) {
#       next;
#     }
#     push @featureLabels, $feature;
#   }
