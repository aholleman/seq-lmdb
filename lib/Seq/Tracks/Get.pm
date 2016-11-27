use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Get;
# Synopsis: For fetching data
# TODO: make this a role?
our $VERSION = '0.001';

use Mouse 2;
use DDP;
extends 'Seq::Tracks::Base';

use Seq::Headers;

has headers => (
  is => 'ro',
  init_arg => undef,
  lazy => 1,
  default => sub { Seq::Headers->new() },
  handles => {
    addFeaturesToHeader => 'addFeaturesToHeader',
    getParentFeatures => 'getParentFeatures',
  }
);

sub BUILD {
  my $self = shift;

  # Skip accesor penalty, the get function in this package may be called
  # billions of times
  $self->{_dbName} = $self->dbName;

  #register all features for this track
  #@params $parent, $child
  #if this class has no features, then the track's name is also its only feature
  if($self->noFeatures) {
    $self->{_noFeatures} = 1;
    return $self->addFeaturesToHeader($self->name);
  }

  $self->addFeaturesToHeader([$self->allFeatureNames], $self->name);
  $self->{_fieldNameMap} = { map { $self->getFieldDbName($_) => $_ } $self->allFeatureNames };
  $self->{_fieldDbNames} = [ map { $self->getFieldDbName($_) } $self->allFeatureNames ];
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
  
  #internally the feature data is store keyed on the dbName not name, to save space
  # 'some dbName' => someData

  #dbName is simply the track name as stored in the database
  #this is handled transparently to use, we just need to call $self->dbName

  #we do this to save space in the database, by a huge number of bytes
  #dbName defined in Seq::Tracks::Base
  if(!defined $_[1]->[ $_[0]->{_dbName} ] ) {
    #interestingly, perl may complain in map { $_ => $_->get($dataHref) } @tracks
    #if undef is not explicitly returned
    return undef;
  }

  #some features simply don't have any features, and for those just return
  #the value they stored
  if($_[0]->{_noFeatures}) {
    return $_[1]->[ $_[0]->{_dbName} ];
  }

  # We have features, so let's find those and return them
  # Since all features are stored in some shortened form in the db, we also
  # will first need to get their dbNames ($self->getFieldDbName)
  # and these dbNames will be found as a value of $href->{$self->dbName}

  #return a hash reference
  #$_[0] == $self, $_[1] == $href, $_ the current value from the array passed to map
  #map is substantially faster than other kinds of for loops
  return [
    #reads:$self->{_fieldNameMap}{$_} => $href->[$self->{_dbName}  ][ $_ ] } @{ $self->{_fieldDbNames} }
    map { $_[1]->[ $_[0]->{_dbName} ][ $_ ] } @{ $_[0]->{_fieldDbNames} }
  ]
}

# sub getIndel {
#   # Same as get, but assumes that the $href (database data) is an array that
#   # covers many positions
#   #my ($self, $dbDataAref) = @_;
#   my %out;

#   for my $fieldDbName (@{ $_[0]->{_fieldDbNames} }) {
#     # $out{ $self->{_fieldNameMap}{$fieldDbName} } = [ map {
#     #   ref $_->[$fieldDbName] ? @{ $_->[$fieldDbName] } : $_->[$fieldDbName]
#     # } map { $_->[  $self->{_dbName} ] } @{$dbDataAref} ]
#     $out{ $_[0]->{_fieldNameMap}{$fieldDbName} } = [ map {
#       ref $_->[$fieldDbName] ? @{ $_->[$fieldDbName] } : $_->[$fieldDbName]
#     } map { $_->[  $_[0]->{_dbName} ] } @{$_[1]} ]
#   }

#   return %out;
# }

__PACKAGE__->meta->make_immutable;

1;

#TODO: figure out how to neatly add feature exclusion, if it's useful
