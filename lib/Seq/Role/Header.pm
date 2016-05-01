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
state $headerFeaturesHref;
#state $headerOrderAref;

sub getHeaderHref {
  return $headerFeaturesHref;
}

#not all children will have parents
sub addFeaturesToOutputHeader {
  if(ref $_[1] eq 'ARRAY') {
    goto &_addFeaturesToOutputHeaderBulk;
  }

  my ($self, $child, $parent, $prepend) = @_;

  if(defined $parent) {
    if(defined $headerFeaturesHref->{$parent}->{$child} ) {
      return;
    }
    $headerFeaturesHref->{$parent}->{$child} = 1;
    # if($prepend) {
    #   unshift @$headerOrderAref, 
    # }
    return;
  }

  $headerFeaturesHref->{$child} = 1;
}

sub _addFeaturesToOutputHeaderBulk {
  if(!ref $_[1]) {
    goto &addFeaturesToOutputHeaderBulk;
  }

  #$self == $_[0], $childrenAref == $_[1]
  my ($self, $childrenAref, $parent, $prepend) = @_;

  for my $child (@$childrenAref) {
    $self->addFeaturesToOutputHeader($child, $parent, $prepend);
  }
  return;
}

#TODO: allow ordering , this is the beginnings of that
# state $headersAref;

# if(!$headersAref) {
#   $headersAref = [];
# }

# has headerFeatureNames => (
#   is => 'ro',
#   isa => 'ArrayRef',
#   traits => ['Array'],
#   handles => {
#     allHeaderFeatureNames => 'elements',
#   },
#   lazy => 1,
#   init_arg => undef,
#   default => sub { $headersAref },
# );

# #not all children will have parents
# sub appendFeaturesToOutputHeader {
#   if(ref $_[1] eq 'ARRAY') {
#     goto &_addFeaturesToOutputHeaderBulk;
#   }

#   #$self == $_[0], $child == $_[1]
#   my ($self, $child, $parent) = @_;

#   if(defined $parent) {
#     if(!exists $headerKeysHref->{$parent} || !exists $headerKeysHref->{$parent}->{$child} ) {
      
#     }
#     $headerKeysHref->{$parent}->{$child} = 1;
#     return;
#   }

#   $headerKeysHref->{$child} = 1;
# }

# sub appendFeaturesToOutputHeaderBulk {
#   if(!ref $_[1]) {
#     goto &addFeaturesToOutputHeaderBulk;
#   }

#   #$self == $_[0], $childrenAref == $_[1]
#   my ($self, $childrenAref, $parent) = @_;

#   for my $child (@$childrenAref) {
#     $self->addFeaturesToOutputHeader($child, $parent);
#   }
#   return;
# }

# sub prependFeaturesToOutputHeader {
#   if(ref $_[1] eq 'ARRAY') {
#     goto &_addFeaturesToOutputHeaderBulk;
#   }

#   #$self == $_[0], $child == $_[1]
#   my ($self, $child, $parent) = @_;

#   if(defined $parent) {
#     $headerKeysHref->{$parent}->{$child} = 1;
#     return;
#   }

#   $headerKeysHref->{$child} = 1;
# }

# sub prependFeaturesToOutputHeaderBulk {
#   if(!ref $_[1]) {
#     goto &addFeaturesToOutputHeaderBulk;
#   }

#   #$self == $_[0], $childrenAref == $_[1]
#   my ($self, $childrenAref, $parent) = @_;

#   for my $child (@$childrenAref) {
#     $self->addFeaturesToOutputHeader($child, $parent);
#   }
#   return;
# }

use Moose::Role;
1;