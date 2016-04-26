#This package manages the mapping of any property stored in the database
#Lets say that we have in the chr1 database position 1 million
# 1e6 => { someField => someValue, someOtherField => otherValue}
# this package is meant to translate some human readable someField
# into a number, because numbers can be stored efficiently by serializers
# like MessagePack

#TODO: finish, to simplify name management
use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base::MapFieldNames;
use Moose::Role;
use List::Util qw/max/;

with 'Seq::Role::Message', 'Seq::Role::DBManager';

#the feature name
requires 'name';

#the hash of names => dbName map
state $fieldNamesMap;
#the hash of dbNames => names
state $fieldDbNamesMap;


#For a $self->name (track name) get a specific field database name
#Expected to be used during database building
#If the fieldName doesn't have a corresponding database name, make one, store,
#and return it
sub getFieldDbName {
  my ($self, $fieldName) = @_;

  if (! exists $fieldNamesMap->{$self->name} ) {
    $self->fetchMetaFields();
  }

  if(! exists $fieldNamesMap->{$self->name}->{$fieldName} ) {
    $self->addMetaField($fieldName);
  }

  return $fieldNamesMap->{$self->name}->{$fieldName};
}

#this function returns the human readable name
#expected to be used during database reading operations
#like annotation
#@param <Number> $fieldNumber : the database name
sub getFieldName {
  my ($self, $fieldNumber) = @_;

  if (! exists $fieldNamesMap->{$self->name} ) {
    $self->fetchMetaFields();
  }

  if(! exists $fieldDbNamesMap->{$self->name}->{$fieldNumber} ) {
    return;
  }

  return $fieldDbNamesMap->{$self->name}->{$fieldNumber};
}

state $metaKey = 'fields';
sub fetchMetaFields {
  my $self = shift;

  my $dataHref = $self->dbGetMeta($self->name, $metaKey) ;

  #if we don't find anything, just store a new hash reference
  #to keep a consistent data type
  if( !$dataHref ) {
    $dataHref = {};
  }

  $fieldNamesMap->{$self->name} = $dataHref;

  #fieldNames map is name => dbName; dbNamesMap is the inverse
  for my $fieldName (keys %$fieldNamesMap) {
    $fieldDbNamesMap->{$self->name}->{$fieldNamesMap->{$fieldName} } = $fieldName;
  }
}

sub addMetaField {
  my $self = shift;
  my $fieldName = shift;

  #https://ideone.com/eX3dOh
  my $fieldNumber = max(keys %$fieldDbNamesMap) + 1;

  my $mapping = {$fieldNumber => $fieldName};

  #need a way of checking if the insertion actually worked
  #but that may be difficult with the currrent LMDB_File API
  #I've had very bad performance returning errors from transactions
  #which are exposed in the C api
  #but I may have mistook one issue for another
  $self->dbPatchMeta($self->name, $metaKey, $mapping);

  $fieldNamesMap->{$self->name}->{$fieldName} = $fieldNumber;
  $fieldDbNamesMap->{$self->name}->{$fieldNumber} = $fieldName;
}
#same as above, but optional, and we don't map within this
#this takes up to 2 arguments, but requires 1: the fields we want to map
#the second is the features we want to get indexes from arg1 for

#I think we always want to return the database name here
#but Region tracks, especially Gene may be an exception
# sub mapFeatureFields {
#   my ($self, $fieldsAref) = @_;

#   if( !$fieldsAref ) {
#     $self->log('error', 'mapFeatureFields requires array ref as first arg');
#   }

#   my %featureIdx;

#   # We don't let the user store required fields in the track they're building
#   # because it's probably not want they want to do
#   # explanation: give me everything unique to the features array (the 2nd array ref)
#   # allFeatureNames returns a list of names, cast as array ref using []
#   for my $field ($self->allFeatureNames) {
#     my $idx = firstidx { $_ eq $field } @$fieldsAref;
   
#     if( ~$idx ) { #means a match was found to the features we want
#       #store the value mapped to the feature name key, this is the 
#       #database name. This is what allows us to have really short feature names in the db
#       my $fname = $self->getFeatureDbName($field);

#       #we've never seen this field before in our lives
#       #let's create a map for it
#       # if(!$fname) {
#       #   $self->addFeatureDbName($field);
#       # }

#       $featureIdx{ $self->getFeatureDbName($field) } = $idx;
#       next;
#     }

#     $self->log('warn', "Feature $field missing in header");
#   }

#   return \%featureIdx;
# }

#For now not used; goal was to make required and featured fields exclusive
#of each other
#Adds a layer of complexity that right now isn't needed
#use: for my $field (_diff( 2, [$self->allRequiredFields], [$self->allFeatureNames] ) ) {
# accepts which array you want the exclusive diff off, and some number of array refs
# ex: _diff(2, $aRef1, $aRef2, $aRef3)
# will return the items that were only found in $aRef2
# http://www.perlmonks.org/?node_id=919422
# Test: https://ideone.com/vxzmPv (adding to test suite as well)
#my @stuff = _diff(3, [0,1,2], [2,3,4], [4,5,6] );
# sub _diff {
#   my $which = shift;
#   my $b = 1;
#   my %presence;

#   foreach my $aRef (@_) {
#       foreach(@$aRef) {
#           $presence{$_} |= $b;
#       }
#   } continue {
#       $b *= 2;
#   }

#   $which = POSIX::floor($which == 1 ? $which : $which * $which/2 );
#   return grep{ $presence{$_} == $which } keys %presence;
# }

# I THINK that roles can modify buildargs

#The mapping of featureDataTypes needs to happens here, becaues if
#the feature is - name :type , that's a hash ref, and features expects 
#ArrayRef[Str].
#we could explicitly check for whether a hash was passed
#but not doing so just means the program will crash and burn if they don't
#note that by not shifting we're implying that the user is submitting an href
#if they don't required attributes won't be found
#so the messages won't be any uglier
# around BUILDARGS => sub {
#   my ($orig, $class, $data) = @_;

#   #if the user passes us a name to store the track as, use that, and map
#   #and map an inverted index
#   #get the value, this is what to store as
#   if(ref $data->{name} eq 'HASH') {
#     #the name is the actual track name; dbName is the interal
#     #we expect name: 
#     ########### 'realName' : 'dbName'
#     #and later we'll generate automatically
#     ( $data->{name}, $data->{_dbName} ) = %{ $data->{name} };
#   }

#   if(!$data->{features} ) {
#     return $class->$orig($data);
#   }
  
#   #we convert the features into a hashRef
#   # {
#   #  featureNameAsAppearsInHeader => <Str> (what we store it as)
#   #}
#   my %featureLabels;
#   for my $feature (@{$data->{features} } ) {
#     if (ref $feature eq 'HASH') {
#       my ($name, $type) = %$feature; #Thomas Wingo method

#       #users can explicilty tell us what they want
#       #-features:
#         # blah:
#           # - type : int
#           # - store : b
#       if(ref $type eq 'HASH') {
#         #must use defined to allow 0 values
#         if( defined $type->{store} ) {
#           $featureLabels{$name} = $type->{store};
#         }
#         #must use defined to allow 0 values (not as nec. here, because 0 type is weird)
#         if( defined $type->{type} ) {
#           #need to use the label, because that is the name that we use
#           #internally
#           $data->{_featureDataTypes}{ $featureLabels{$name} } = $type->{type};
#         }

#         next;
#       }
      
#       $featureLabels{$name} = $name;
#       $data->{_featureDataTypes}{$name} = $type;
#     }
#   }
#   $data->{features} = \%featureLabels;

#   $class->$orig($data);
# };

no Moose::Role;
1;