package Seq::Headers;
use Moose 2;

# Abstract: Responsible for building the header object and string
use 5.10.0;
use strict;
use warnings;
use namespace::autoclean;

#stored as array ref to preserve order
# [ { $parent => [ $child1, $child2 ] }, $feature2, $feature3, etc ]
state $orderedHeaderFeaturesAref = [];

sub get {
  return $orderedHeaderFeaturesAref;
}

#not all children will have parents
sub addFeaturesToHeader {
  my ($self, $child, $parent, $prepend) = @_;

  if(ref $child eq 'ARRAY') {
    goto &_addFeaturesToHeader;
  }

  if($parent) {
    my $parentFound = 0;

    for my $headerEntry (@$orderedHeaderFeaturesAref) {
      my ($key, $valuesAref) = %$headerEntry;

      if($key eq $parent) {

        if($prepend) {
          unshift @$valuesAref, $child;
        } else {
          push @$valuesAref, $child;
        }
        

        $parentFound = 1;
        last;
      }
    }

    if(!$parentFound) {
      my $val = { $parent => [$child] };

      if($prepend) {
        unshift @$orderedHeaderFeaturesAref, $val; 
      } else {
        push @$orderedHeaderFeaturesAref, $val;
      }
      
    }

    return;
  }
  
  my $childFound = 0;

  #if no parent is provided, then we expect that the child is the only
  #value stored, rather than a parentName => [value1, value2]
  for my $headerEntry (@$orderedHeaderFeaturesAref) {
    if($child eq $headerEntry) {
      $childFound = 1;
      last;
    }
  }

  if(!$childFound) {
    if($prepend) {
      unshift @$orderedHeaderFeaturesAref, $child;
    } else {
      push @$orderedHeaderFeaturesAref, $child;
    }
  }
}

sub getString {
  my $self = shift;

  my @out;  
  for my $feature (@$orderedHeaderFeaturesAref) {
    #this is a parentName => [$feature1, $feature2, $feature3] entry
    if(ref $feature) {
      my ($parentName) = %$feature;
      foreach (@{ $feature->{$parentName} } ) {
        push @out, "$parentName.$_";
      }
      next;
    }
    push @out, $feature;
  }

  return join("\t", @out);
}

sub _addFeaturesToHeaderBulk {
  my ($self, $childrenAref, $parent, $prepend) = @_;

  if(!ref $childrenAref) {
    goto &addFeaturesToTrackHeadersBulk;
  }

  for my $child (@$childrenAref) {
    $self->addFeaturesToTrackHeaders($child, $parent, $prepend);
  }

  return;
}

__PACKAGE__->meta->make_immutable;

1;