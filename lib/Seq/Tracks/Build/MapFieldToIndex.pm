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

# I'm purposely not using the all methods, because that seems totally unwieldy
# since I need both the reference and the dereferenced versions
requires 'required_fields';
requires 'features';
requires 'getRequiredFieldType';
#@returns (<String> errorIfAny, <HashRef> required map, <HashRef> optional map)
#has error-last "callbacks" strategy, used by golang
#the consuming module defines the fields it requires
sub mapRequiredFields {
  my $self = shift;

  # the fields from some input file
  my $fieldsAref = shift;

  #sometimes we may want to not allow mapped names
  #for instance when deciding whether we have one type of file, or another
  my $allowAlternativeName = shift; 

  my %reqIdx;

  for my $rName ( @{$self->required_fields} ) {
    my $idx = firstidx {$_ eq $rName} @$fieldsAref; #returns -1 if not found
    #bitwise complement, makes -1 0
    if( ~$idx ) {
      $reqIdx{$rName} = $idx;
      next;  
    }

    if( !$allowAlternativeName ) {
      return (undef, "Required field $rName missing in header,
        and allowAlternativeName flag falsy in mapRequiredFields");
    }

    #two href get should be cheaper but this may be easier to read
    my $trueName = $self->getRequiredFieldType($rName);
    if( $trueName ) {
      $idx = firstidx { $_ eq $trueName } @$fieldsAref;
    }
    
    if ( ~$idx ) {
      $reqIdx{$trueName} = $idx;
      next;
    }

    return (undef, "Required field $rName missing in header");
  }

  return \%reqIdx;
}

#same as above, but optional, and we don't map within this
#this takes up to 2 arguments, but requires 1: the fields we want to map
#the second is the features we want to get indexes from arg1 for
sub mapFeatureFields {
  my ($self, $fieldsAref) = @_;

  if( !$fieldsAref ) {
    $self->tee_logger('error', 'mapFeatureFields requires array ref as first arg');
  }

  my %featureIdx;

  # We don't let the user store required fields in the track they're building
  # because it's probably not want they want to do
  # explanation: give me everything unique to the features array (the 2nd array ref)
  for my $fName ( _featureDiff(2, $self->required_fields, $self->features) ) {
    my $idx = firstidx { $_ eq $fName } @$fieldsAref;
   
    if( ~$idx ) { #only non-0 when non-negative, ~0 > 0
      $featureIdx{$fName} = $idx;
      next;
    }

    $self->tee_logger('warn', "Feature $fName missing in header");
  }

  return \%featureIdx;
}

# accepts which array you want the exclusive diff off, and some number of array refs
# ex: _featureDiff(2, $aRef1, $aRef2, $aRef3)
# will return the items that were only found in $aRef2
# http://www.perlmonks.org/?node_id=919422
# Test: https://ideone.com/3ITgd6 (adding to test suite as well)
sub _featureDiff {
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
  $which = POSIX::floor($which == 1 ? $which : $which * 2);
  return grep{ $presence{$_} == $which } keys %presence;
}
no Moose::Role;
1;