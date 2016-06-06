package Seq::Headers;
use Moose 2;

# Abstract: Responsible for building the header object and string
use 5.10.0;
use strict;
use warnings;
use namespace::autoclean;

with 'Seq::Role::Message';
#stored as array ref to preserve order
# [ { $parent => [ $child1, $child2 ] }, $feature2, $feature3, etc ]
state $orderedHeaderFeaturesAref = [];

sub get {
  return $orderedHeaderFeaturesAref;
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

#not all children will have parents
sub addFeaturesToHeader {
  my ($self, $child, $parent, $prepend) = @_;

  if(ref $child eq 'ARRAY') {
    goto &_addFeaturesToHeaderBulk;
  }

  if($parent) {
    my $parentFound = 0;

    for my $headerEntry (@$orderedHeaderFeaturesAref) {
      if(!ref $headerEntry) {
        if($parent eq $headerEntry) {
          $self->log('warning', "$parent equals $headerEntry, which has no 
            child features, which was not what we expected");
        }
        next;
      }

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

sub _addFeaturesToHeaderBulk {
  my ($self, $childrenAref, $parent, $prepend) = @_;

  if(!ref $childrenAref) {
    goto &addFeaturesToHeader;
  }

  my @array = $prepend ? reverse @$childrenAref : @$childrenAref;

  for my $child (@array) {
    $self->addFeaturesToHeader($child, $parent, $prepend);
  }

  return;
}

__PACKAGE__->meta->make_immutable;

1;