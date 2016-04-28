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

state $headerKeysHref;

sub addHeaderKey {
  if(!exists $headerKeysHref->{$_[1] } ) {
    $headerKeysHref->{ $_[1] } = 1;
  }
}

sub getAllHeaderKeys {
  return keys %$headerKeysHref;
}

use Moose::Role;
1;