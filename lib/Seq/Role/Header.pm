#This role helps us to figure out all that the user requested
#We don't want to output anything that wasn't asked for
#Two methods, addHeaderKey, and getAllHeaderKeys
#This is also a singleton, because we compose our classes
#Which makes our header emergent
#For instance, while we know at run time what all the user asked for
#By looking at the features listed under tracks
#We won't know at run time 
package Seq::Role::Header;
use 5.10.0;
use strict;
use warnings;
use namespace::autoclean;
use DDP;
state $headerKeysHref;

sub getHeaderHref {
  return $headerKeysHref;
}

#not all children will have parents
sub addFeaturesToHeader {
  if(ref $_[1] eq 'ARRAY') {
    goto &_addFeaturesToHeaderBulk;
  }

  #$self == $_[0], $child == $_[1]
  my ($self, $child, $parent) = @_;

  if(defined $parent) {
    $headerKeysHref->{$parent}->{$child} = 1;
    return;
  }

  $headerKeysHref->{$child} = 1;
}

sub _addFeaturesToHeaderBulk {
  if(!ref $_[1]) {
    goto &addFeaturesToHeaderBulk;
  }

  #$self == $_[0], $childrenAref == $_[1]
  my ($self, $childrenAref, $parent) = @_;

  for my $child (@$childrenAref) {
    $self->addFeaturesToHeader($child, $parent);
  }
  return;
}

use Moose::Role;
1;