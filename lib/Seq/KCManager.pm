use 5.10.0;
use strict;
use warnings;

package Seq::KCManager;

our $VERSION = '0.001';

# ABSTRACT: Manages KyotoCabinet db
# VERSION

=head1 DESCRIPTION

  @class B<Seq::KCManager>
  #TODO: Check description

  @example

Used in:
=for :list
* Seq::Annotate
* Seq::Build::GeneTrack

Extended by: None

=cut

use Moose 2;
use Moose::Util::TypeConstraints;
with 'MooseX::SimpleConfig';

use Carp;
use Cpanel::JSON::XS qw/encode_json decode_json/;
use LMDB_File qw(:flags :cursor_op);
use Hash::Merge::Simple qw/ merge /;
use Type::Params qw/ compile /;
use Types::Standard qw/ :types /;

with 'Seq::Role::IO';

#the build config file
has db_path => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

# mode: - read or create
has read_only => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
);

has _env => (
  is => 'ro',
  lazy => 1,
  builder => '_buildEnv',
);

has _dbi => (
  is => 'ro',
  lazy => 1,
  builder => '_makeDbi',
);

sub _buildEnv {
  my $self = shift;

  my $read_mode = $self->read_only ? MDB_RDONLY : '';
  return LMDB::Env->new($self->db_path, {
    mapsize => 1024 * 1024 * 1024 * 1024, # Plenty space, don't worry
    maxdbs => 0, #database isn't named, identified by path alone
    flags => MDB_NOMETASYNC | MDB_NOTLS | $read_mode
  });
}

sub _makeDbi {
  my ($self, $create) = @_;

  my $create_if_not_found = $create && !$self->read_only ? MDB_CREATE : '';
  my $txn = $self->_env->BeginTxn();

  my $dbi = $txn->open( {
    flags => $create_if_not_found ? MDB_CREATE : '',
  });
  $txn->commit();
  return $dbi;
}

# rationale - hashes cannot really have duplicate keys; so, to circumvent this
# issue we'll check to see if there's data there at they key first, unpack it
# and add our new data to it and then store the merged data
sub db_put {
  my ( $self, $key, $href ) = @_;

  my $txn = $self->_env->BeginTxn();

  $txn->put($key, encode_json($href) ); #overwrites existing values

  $txn->commit();
}

# @param [HashRef[HashRef] ] $kvAref ; $key => {}, $key2 => {}
sub db_put_bulk {
  my ( $self, $kvHref ) = @_;

  my $txn = $self->_env->BeginTxn();

  for my $key (keys %{$kvHref} ) {
    $txn->put($self->_dbi, $key, encode_json($kvHref->{$key} ) ); #overwrites existing values
  }
  
  $txn->commit();
}

sub db_patch {
  my ( $self, $key, $new_href) = @_;

  my $txn = $self->_env->BeginTxn();

  my $previous_href;

  $txn->get($self->_dbi, $key, $previous_href);

  if($previous_href) {
    $previous_href = decode_json($previous_href);
    $previous_href = merge $previous_href, $new_href; #righthand merge
  } else {
    $previous_href = $new_href;
  }

  $txn->put($self->_dbi, $key, encode_json($previous_href) );

  $txn->commit();
}

sub db_patch_bulk {
  my ( $self, $kvHref ) = @_;

  my $txn = $self->_env->BeginTxn();

  for my $key (keys $kvHref) {
    my $previous_href;

    $txn->get($self->_dbi, $key, $previous_href);

    if($previous_href) {
      $previous_href = decode_json($previous_href);
      $previous_href = merge $previous_href, $kvHref->{$key}; #righthand merge
    } else {
      $previous_href = $kvHref->{$key};
    }

    $txn->put($self->_dbi, $key, encode_json($previous_href) );
  }

  $txn->commit();
}

sub db_get {
  my ( $self, $keys ) = @_;

  # the reason we need to check the existance of the db has to do with that we
  # allow non-existant file names to be used in creating the object and since
  # the creation of the _db attribute is done in a lazy way we may never need to
  # bother checking the file system or opening the databse.
  my $dbm = $self->_db;

  # does dbm doesn't exist?
  my $val;
  if ( defined $dbm ) {
    $val = $dbm->get($keys);

    # does the value exist within the dbm?
    if ( defined $val ) {
      return decode_json $val;
    }
    else {
      return;
    }
  }
  else {
    return;
  }
}

sub db_bulk_get {
  my ( $self, $keys, $reverse ) = @_;

  # the reason we need to check the existance of the db has to do with that we
  # allow non-existant file names to be used in creating the object and since
  # the creation of the _db attribute is done in a lazy way we may never need to
  # bother checking the file system or opening the databse.
  my $dbm = $self->_db;

  # does dbm doesn't exist?
  my $val;
  if ( defined $dbm ) {

    # keys is assumed to be an array reference
    $val = $dbm->get_bulk($keys);

    # does the value exist within the dbm?
    if ( defined $val ) {
      if ($reverse) {
        return map { decode_json( $val->{$_} ) } sort { $b <=> $a } keys(%$val);
      }
      return map { decode_json( $val->{$_} ) } sort { $a <=> $b } keys(%$val);
    }
    else {
      return;
    }
  }
  else {
    return;
  }
}

__PACKAGE__->meta->make_immutable;

1;
