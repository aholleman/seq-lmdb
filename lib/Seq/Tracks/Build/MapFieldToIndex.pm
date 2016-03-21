package Seq::Tracks::Build::MapFieldToIndex;
# Synopsis: An abstract class for mapping field names in the input file
# to required and optional features
# (required being typically chrom chromStart chromEnd)

#TODO: we could think about putting all feature code here
#including feature type mapping, required field mapping

use strict;
use warnings;
use Moose::Role;
use List::MoreUtils::XS qw(firstidx);
use POSIX;
with 'Seq::Role::Message';

requires 'allRequiredFields';
requires 'getReqFieldDbName';

requires 'allFeatureNames';
requires 'getFeatureDbName';

#@returns (<String> errorIfAny, <HashRef> required map, <HashRef> optional map)
#has error-last "callbacks" strategy, used by golang
#the consuming module defines the fields it requires
sub mapRequiredFields {
  my ($self, $fieldsAref) = @_;

  my %reqIdx;

  for my $field ($self->allRequiredFields) {
    my $idx = firstidx { $_ eq $field } @$fieldsAref; #returns -1 if not found
    #bitwise complement, makes -1 0
    if( ~$idx ) {
      $reqIdx{ $self->getReqFieldDbName($field) } = $idx;
      next;  
    }

    return (undef, "Required field $field missing in header");
  }

  return \%reqIdx;
}

#same as above, but optional, and we don't map within this
#this takes up to 2 arguments, but requires 1: the fields we want to map
#the second is the features we want to get indexes from arg1 for
sub mapFeatureFields {
  my ($self, $fieldsAref) = @_;

  if( !$fieldsAref ) {
    $self->log('error', 'mapFeatureFields requires array ref as first arg');
  }

  my %featureIdx;

  # We don't let the user store required fields in the track they're building
  # because it's probably not want they want to do
  # explanation: give me everything unique to the features array (the 2nd array ref)
  # allFeatureNames returns a list of names, cast as array ref using []
  for my $field (_diff( 2, [$self->allRequiredFields], [$self->allFeatureNames] ) ) {
    my $idx = firstidx { $_ eq $field } @$fieldsAref;
   
    if( ~$idx ) {
      #store the value mapped to the feature name key, this is the 
      #database name. This is what allows us to have really short feature names in the db
      $featureIdx{ $self->getFeatureDbName($field) } = $idx;
      next;
    }

    $self->log('warn', "Feature $field missing in header");
  }

  return \%featureIdx;
}

# accepts which array you want the exclusive diff off, and some number of array refs
# ex: _diff(2, $aRef1, $aRef2, $aRef3)
# will return the items that were only found in $aRef2
# http://www.perlmonks.org/?node_id=919422
# Test: https://ideone.com/vxzmPv (adding to test suite as well)
#my @stuff = _diff(3, [0,1,2], [2,3,4], [4,5,6] );
sub _diff {
  my $which = shift;
  my $b = 1;
  my %presence;

  foreach my $aRef (@_) {
      foreach(@$aRef) {
          $presence{$_} |= $b;
      }
  } continue {
      $b *= 2;
  }

  $which = POSIX::floor($which == 1 ? $which : $which * $which/2 );
  return grep{ $presence{$_} == $which } keys %presence;
}

no Moose::Role;
1;