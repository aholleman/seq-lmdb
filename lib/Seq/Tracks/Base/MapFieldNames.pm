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
use Moose::Role 2;
use List::Util qw/max/;
use DDP;
use Seq::DBManager;

with 'Seq::Role::Message';

#the feature name
requires 'name';

#the hash of names => dbName map
state $fieldNamesMap;
#the hash of dbNames => names
state $fieldDbNamesMap;

#Under which key fields are mapped in the meta database belonging to the
#consuming class' $self->name
#in roles that extend this role, this key's default can be overloaded
state $metaKey = 'fields';
#For a $self->name (track name) get a specific field database name
#Expected to be used during database building
#If the fieldName doesn't have a corresponding database name, make one, store,
#and return it
#may be called millions of times, so skipping assignment of args
has debug => (is => 'ro');

my $db = Seq::DBManager->new();
sub getFieldDbName {
  #my ($self, $fieldName) = @_;
  
  #$self = $_[0]
  #$fieldName = $_[1]
  if (! exists $fieldNamesMap->{$_[0]->name} ) {
    $_[0]->fetchMetaFields();
  }

  if(! exists $fieldNamesMap->{$_[0]->name}->{ $_[1] } ) {
    $_[0]->addMetaField( $_[1] );
  }
  
  return $fieldNamesMap->{$_[0]->name}->{$_[1]};
}

#this function returns the human readable name
#expected to be used during database reading operations
#like annotation
#@param <Number> $fieldNumber : the database name
sub getFieldName {
  my ($self, $fieldNumber) = @_;

  #$self = $_[0]
  #$fieldNumber = $_[1]
  if (! exists $fieldNamesMap->{ $_[0]->name } ) {
    $_[0]->fetchMetaFields();
  }

  if(! exists $fieldDbNamesMap->{ $_[0]->name }->{ $_[1] } ) {
    return;
  }

  return $fieldDbNamesMap->{ $_[0]->name }->{ $_[1] };
}


sub fetchMetaFields {
  my $self = shift;

  my $dataHref = $db->dbReadMeta($self->name, $metaKey) ;

  if ($self->debug) {
    say "Currently, fetchMetaFields found";
    p $dataHref;
  }

  #if we don't find anything, just store a new hash reference
  #to keep a consistent data type
  if( !$dataHref ) {
    $fieldNamesMap->{$self->name} =  {};
    $fieldDbNamesMap->{$self->name} = {};
    return;
  }

  $fieldNamesMap->{$self->name} = $dataHref;
  #fieldNames map is name => dbName; dbNamesMap is the inverse
  for my $fieldName (keys %$dataHref) {
    $fieldDbNamesMap->{$self->name}{ $dataHref->{$fieldName} } = $fieldName;
  }
}

sub addMetaField {
  my $self = shift;
  my $fieldName = shift;

  my @fieldKeys = keys %{ $fieldDbNamesMap->{$self->name} };
  
  if($self->debug) {
    say "in addMetaField, fields keys are";
    p @fieldKeys;
    
    say "fieldDbNames";
    p $fieldDbNamesMap;
  }
  
  my $fieldNumber;
  if(!@fieldKeys) {
    $fieldNumber = 0;
  } else {
    #https://ideone.com/eX3dOh
    $fieldNumber = max(@fieldKeys) + 1;
  }
  
  #need a way of checking if the insertion actually worked
  #but that may be difficult with the currrent LMDB_File API
  #I've had very bad performance returning errors from transactions
  #which are exposed in the C api
  #but I may have mistook one issue for another
  #passing 1 to overwrite existing fields
  #since the below mapping ends up relying on our new values
  $db->dbPatchMeta($self->name, $metaKey, {
    $fieldName => $fieldNumber
  }, 1);

  $fieldNamesMap->{$self->name}->{$fieldName} = $fieldNumber;
  $fieldDbNamesMap->{$self->name}->{$fieldNumber} = $fieldName;
}

no Moose::Role;
1;