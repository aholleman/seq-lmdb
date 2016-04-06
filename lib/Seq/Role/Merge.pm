use 5.10.0;
use strict;
use warnings;

package Seq::Role::Merge;
use Moose::Role 2;

# to comply with Merge::Simple, right hand takes precedence
# unless overwrite is set
# and this only works for 2 hash references
sub shallowMerge {
  #expects
  # my $self = shift; $_[0]
  # my $href1 = shift; $_[1]
  # my $href2 = shift; $_[2]
  # my $overwrite = shift; $_[3]
  for my $attr1 ( keys %{ $_[2] } ) {
    #if we want to overwrite, we overwrite the left thing
    #since right takes
    if( $_[3] &&  exists $_[2]->{$attr1} ) {
      $_[1]->{$attr1} = $_[2]->{$attr1};
      next;
    }

    if( $_[3] || !exists $_[2]->{$attr1} ) {
      $_[2]->{$attr1} = $_[1]->{$attr1};
    }
  }
}

no Moose::Role;
