use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Get;
# Synopsis: For fetching data
# TODO: make this a role?
our $VERSION = '0.001';

use Moose 2;

extends 'Seq::Tracks::Base';

#exports $self->addFeaturesToTrackHeaders
with 'Seq::Tracks::Headers';

sub BUILD {
  my $self = shift;

  #register all features for this track
  #@params $parent, $child
  #if this class has no features, then the track's name is also its only feature
  if($self->noFeatures) {
    return $self->addFeaturesToTrackHeaders($self->name);
  }

  $self->addFeaturesToTrackHeaders([$self->allFeatureNames], $self->name);
}

# Take a hash (that is passed to this function), and get back all features
# that belong to thie Track
# @param <Seq::Tracks::Any> $self
# @param <HashRef> $href : The raw data (presumably from the database);
# @return <HashRef> : A hash ref of featureName => featureValue pairs for
# all features the user specified for this Track in their config file
sub get {
  #$href is the data that the user previously grabbed from the database
  #my ($self, $href) = @_;
  # so $_[0] is $self, $_[1] is $href; 

  if(ref $_[1] eq 'ARRAY') {
    goto &getBulk;
  }
  

  #internally the feature data is store keyed on the dbName not name, to save space
  # 'some dbName' => someData

  #dbName is simply the track name as stored in the database
  #this is handled transparently to use, we just need to call $self->dbName

  #we do this to save space in the database, by a huge number of bytes
  #dbName defined in Seq::Tracks::Base
  if(!exists $_[1]->{ $_[0]->dbName } ) {
    #interestingly, perl may complain in map { $_ => $_->get($dataHref) } @tracks
    #if undef is not explicitly returned
    return undef;
  }

  #some features simply don't have any features, and for those just return
  #the value they stored
  if($_[0]->noFeatures) {
    return $_[1]->{$_[0]->dbName};
  }

  # We have features, so let's find those and return them
  # Since all features are stored in some shortened form in the db, we also
  # will first need to get their dbNames ($self->getFieldDbName)
  # and these dbNames will be found as a value of $href->{$self->dbName}

  #return a hash reference
  #$_[0] == $self, $_[1] == $href, $_ the current value from the array passed to map
  return {
    map { $_ => $_[1]->{ $_[0]->dbName }{ $_[0]->getFieldDbName($_) } } $_[0]->allFeatureNames 
  }
}

sub getBulk {
  # Here $self == $_[0] , $aRefOfDataHrefs == $_[1]
  if(ref $_[1] eq 'HASH') {
    goto &get;
  }

  #http://www.perlmonks.org/?node_id=596282
  return [ map { $_[0]->get($_) } @{ $_[1] } ];
}

__PACKAGE__->meta->make_immutable;

1;

#TODO: figure out how to neatly add feature exclusion, if it's userful
# sub BUILD {
#   my $self = shift;
#   #once feature exclusion is ready 
#   # my @includedFeatures;

#   # for my $feature ($self->allFeatureNames) {
#   #   if(!first{ $_ eq $feature } @{$self->annotation_exclude_features} ) {
#   #     push @includedFeatures, $feature;
#   #   }
#   # } 
#   # $self->addFeaturesToTrackHeaders(\@includedFeatures $self->name);
# }
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
