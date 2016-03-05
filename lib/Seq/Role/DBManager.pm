use 5.10.0;
use strict;
use warnings;

package Seq::Role::DBManager;

our $VERSION = '0.001';

# ABSTRACT: Manages Database connection
# VERSION

=head1 DESCRIPTION

  @class B<Seq::DBManager>
  #TODO: Check description

  @example
# A singleton role; must be configured by some process before use
Used in:
=for :list



=cut

use Moose::Role;
with 'MooseX::SimpleConfig';

use Carp;
use Cpanel::JSON::XS qw/encode_json decode_json/;
use LMDB_File qw(:flags :cursor_op);
use Hash::Merge::Simple qw/ merge /;
use MooseX::Types::Path::Tiny qw/AbsDir/;

#the build config file
state $database_dir;
has database_dir => (
  is       => 'ro',
  isa      => AbsDir,
  default  => sub{$database_dir},
  coerce   => 1,
  writer => 'setDbPath',
);

# mode: - read or create
has read_only => (
  is => 'ro',
  isa => 'Bool',
  default => 1,
);

#using state to make implicit singleton for the state that we want
#shared across all instances, without requiring exposing to public
#at the moment we generate a new environment for each $name
#because we can only have one writer per environment,
#across all threads
#and because there is some minor overhead with opening many named databases
sub getEnv {
  my ($self, $name) = @_;
  state $envs;

  return $envs->{$name} if $envs->{$name};

  my $read_mode = $self->read_only ? MDB_RDONLY : '';

  #IMPORTANT: can't use MDB_WRITEMAP safely, unless we are sure that
  #the underlying file system supports sparse files
  #else, the entire mapsize will be written at once
  my $dbPath = $self->database_dir->child($name)->stringify;
  $envs->{$name} = LMDB::Env->new($dbPath, {
    mapsize => 1024 * 1024 * 1024 * 1024, # Plenty space, don't worry
    maxdbs => 0, #database isn't named, identified by path alone
    flags => MDB_NOMETASYNC | MDB_NOTLS | $read_mode
  });

  return $envs->{$name};
}

sub getDbi {
  my ($self, $name) = @_;
  state $envs;
  state $dbis;

  return $dbis->{$name} if defined $dbis->{$name};

  $envs->{$name} = $self->getEnv($name) if !$envs->{$name};

  my $txn = $envs->{$name}->BeginTxn();

  $dbis->{$name} = $txn->open( {
    flags => $self->read_only ? MDB_CREATE : '',
  });

  $txn->commit();
  return $dbis->{$name};
}

# rationale - hashes cannot really have duplicate keys; so, to circumvent this
# issue we'll check to see if there's data there at they key first, unpack it
# and add our new data to it and then store the merged data
sub dbPut {
  my ( $self, $chr, $pos, $href ) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->BeginTxn();

  $txn->put($dbi, $pos, encode_json($href) ); #overwrites existing values

  $txn->commit();
}

# @param [HashRef[HashRef] ] $kvAref ; $key => {}, $key2 => {}
sub dbPutBulk {
  my ( $self, $chr, $posHref ) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->BeginTxn();

  for my $pos (keys %{$posHref} ) {
    $txn->put($dbi, $pos, encode_json($posHref->{$pos} ) ); #overwrites existing values
  }
  
  $txn->commit();
}

sub dbPatch {
  my ( $self, $chr, $pos, $new_href) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->BeginTxn();

  my $previous_href;

  $txn->get($dbi, $pos, $previous_href);

  if($previous_href) {
    $previous_href = decode_json($previous_href);
    $previous_href = merge $previous_href, $new_href; #righthand merge
  } else {
    $previous_href = $new_href;
  }

  $txn->put($dbi, $pos, encode_json($previous_href) );

  $txn->commit();
}

sub dbPatchBulk {
  my ( $self, $chr, $posHref ) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->BeginTxn();

  for my $pos (keys %{$posHref} ) {
    my $previous_href;

    $txn->get($dbi, $pos, $previous_href);

    if($previous_href) {
      $previous_href = decode_json($previous_href);
      $previous_href = merge $previous_href, $posHref->{$pos}; #righthand merge
    } else {
      $previous_href = $posHref->{$pos};
    }

    $txn->put($dbi, $pos, encode_json($previous_href) );
  }

  $txn->commit();
}

sub dbGet {
  my ( $self, $chr, $pos ) = @_;

  # the reason we need to check the existance of the db has to do with that we
  # allow non-existant file names to be used in creating the object and since
  # the creation of the _db attribute is done in a lazy way we may never need to
  # bother checking the file system or opening the databse.
  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->BeginTxn();

  my $val;

  $txn->get($dbi, $pos, $val);

  $txn->commit();

  if ( defined $val ) {
    return decode_json $val;
  }
  else {
    return;
  }
}

no Moose::Role;

1;


#we could also make all dbs at once, but I dont really see the benefit
# has genome_chrs => (
#   is => 'ro',
#   isa => 'ArrayRef',
#   required => 1,
# );

# sub BUILDARGS {
#   my $class = shift;
#   my $argsHref  = $_[0];

#   if (@dbNames) {
#     $argsHref->{dbNames} = \@dbNames;
#   } else {
#     @dbNames = @{$argsHref->{dbNames} };
#   }

#   return $class->SUPER::BUILDARGS( $argsHref );
# };

# sub _buildAllEnvs {
#   my $self = shift;

#   return %env if %env;

#   my $read_mode = $self->read_only ? MDB_RDONLY : '';

#   for my $dbName (@dbNames) {
#     $env{$dbName} = LMDB::Env->new($self->db_path, {
#       mapsize => 1024 * 1024 * 1024 * 1024, # Plenty space, don't worry
#       maxdbs => 0, #database isn't named, identified by path alone
#       flags => MDB_NOMETASYNC | MDB_NOTLS | $read_mode
#     });
#   }

#   return $env;
# }