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

use Carp;
use Cpanel::JSON::XS qw/encode_json decode_json/;
use LMDB_File qw(:all);
use Hash::Merge::Simple qw/ merge /;
use MooseX::Types::Path::Tiny qw/AbsDir/;
use DDP;

$LMDB_File::die_on_err = 0;
#needed so that we can initialize DBManager onces
state $databaseDir;
has database_dir => (
  is       => 'ro',
  isa      => AbsDir,
  lazy => 1, 
  required => 1,
  default => sub{$databaseDir},
  coerce   => 1,
  handles => {
    dbPath => 'stringify',
  }
);

sub setDbPath {
  $databaseDir = $_[1]; #$_[0] is $self
}
# mode: - read or create
has read_only => (
  is => 'rw',
  isa => 'Bool',
  lazy => 1,
  default => 1,
);

#using state to make implicit singleton for the state that we want
#shared across all instances, without requiring exposing to public
#at the moment we generate a new environment for each $name
#because we can only have one writer per environment,
#across all threads
#and because there is some minor overhead with opening many named databases

sub getDbi {
  my ($self, $name) = @_;
  state $dbis;
  state $envs;

  return $dbis->{$name} if defined $dbis->{$name};
  
  my $dbPath = $self->database_dir->child($name);
  if(!$self->database_dir->child($name)->is_dir) {
    $self->database_dir->child($name)->mkpath;
  }

  $dbPath = $dbPath->stringify;

  $envs->{$name} = $envs->{$name} ? $envs->{$name} : LMDB::Env->new($dbPath, {
      mapsize => 1024 * 1024 * 1024 * 1024, # Plenty space, don't worry
      #maxdbs => 20, # Some databases
      mode   => 0755,
      # More options
  });

  my $txn = $envs->{$name}->BeginTxn(); # Open a new transaction

  my $DB = $txn->open( #{    # Create a new database
    undef, !$self->read_only ? MDB_CREATE : 0,
  );

  $txn->commit();
  # # my $env = $self->getEnv($name);

  # # my $txn = $env->BeginTxn();

  # # $dbis->{$name} = {
  # #   env => $env,
  # #   dbi => $txn->OpenDB({
  # #     dbname => $name, 
  # #     flags  => MDB_CREATE | !$self->read_only ? MDB_CREATE : 0
  # #   }),
  # # };

  $envs->{$name}->set_flags(
    MDB_NOMETASYNC | MDB_NOTLS | $self->read_only ? MDB_RDONLY : 0,
    1
  );
  # #don't work when creating database flags => MDB_NOMETASYNC | MDB_NOTLS | $self->read_only ? MDB_RDONLY : 0,
  # say "dbis->name is";
  # p $dbis->{$name};
  # # this seems to fail at actually creating ONLY if not exists
  # # {
  # #   flags => !$self->read_only ? MDB_CREATE : 0,
  # # }
  
  # $txn->commit();
  $dbis->{$name} = {
    dbi => $DB,
    env => $envs->{$name},
  };

  return $dbis->{$name};
}

# I had wanted to use low-level transactions, but these seem to have
# rationale - hashes cannot really have duplicate keys; so, to circumvent this
# issue we'll check to see if there's data there at they key first, unpack it
# and add our new data to it and then store the merged data
sub dbPut {
  my ( $self, $chr, $pos, $href ) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->{env}->BeginTxn();

  $txn->put($dbi->{dbi}, $pos, encode_json($href) ); #overwrites existing values

  $txn->commit();
}

# @param [HashRef[HashRef] ] $kvAref ; $key => {}, $key2 => {}
sub dbPutBulk {
  my ( $self, $chr, $posHref ) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->{env}->BeginTxn();

  for my $pos (keys %{$posHref} ) {
    $txn->put($dbi->{dbi}, $pos, encode_json($posHref->{$pos} ) ); #overwrites existing values
  }
  
  $txn->commit();
}

sub dbPatch {
  my ( $self, $chr, $pos, $new_href) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->{env}->BeginTxn();

  my $previous_href;

  $txn->get($dbi->{dbi}, $pos, $previous_href);

  if($previous_href) {
    $previous_href = decode_json($previous_href);
    $previous_href = merge $previous_href, $new_href; #righthand merge
  } else {
    $previous_href = $new_href;
  }

  $txn->put($dbi->{dbi}, $pos, encode_json($previous_href) );

  $txn->commit();
}

#TODO: we should allow an array ref, more memory efficient
sub dbPatchBulk {
  my ( $self, $chr, $posHref ) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->{env}->BeginTxn();

  for my $pos (keys %{$posHref} ) {
    my $previous_href;

    $LMDB_File::last_err = 0;
    $txn->get($dbi->{dbi}, $pos, $previous_href);
    if($LMDB_File::last_err) {
     # say "nothing found";
    } elsif ($self->debug) {
      say "previous value was";
      p $previous_href;
    }

   # say "Last error is " . $LMDB_File::last_err;
    if($previous_href) {
      $previous_href = decode_json($previous_href);
      $previous_href = merge $previous_href, $posHref->{$pos}; #righthand merge
    } else {
      $previous_href = $posHref->{$pos};
    }

    $txn->put($dbi->{dbi}, $pos, encode_json($previous_href) );
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
  my $txn = $dbi->{env}->BeginTxn();

  my $val;

  $txn->get($dbi->{dbi}, $pos, $val);

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

# sub getEnv {
#   my ($self, $name) = @_;
#   state $envs;

#   return $envs->{$name} if $envs->{$name};

#   #IMPORTANT: can't use MDB_WRITEMAP safely, unless we are sure that
#   #the underlying file system supports sparse files
#   #else, the entire mapsize will be written at once
#   my $dbPath = $self->database_dir->child($name);
#   if(!$self->database_dir->child($name)->is_dir) {
#     $self->database_dir->child($name)->mkpath;
#   }

#   $dbPath = $dbPath->stringify;

#   say "dbPath is $dbPath/";
#   #don't work when creating database flags => MDB_NOMETASYNC | MDB_NOTLS | $self->read_only ? MDB_RDONLY : 0,

#   $envs->{$name} = LMDB::Env->new($dbPath, {
#     mapsize => 1024 * 1024 * 1024 * 1024, # Plenty space, don't worry
#     maxDbs => 1,
#   });

#   return $envs->{$name};
# }