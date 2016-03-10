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
use MooseX::Types::Path::Tiny qw/AbsPath/;
use DDP;

$LMDB_File::die_on_err = 0;
#needed so that we can initialize DBManager onces
state $databaseDir;
#we'll make the database_dir if it doesn't exist in the buid step
has database_dir => (
  is => 'ro',
  isa => AbsPath,
  coerce => 1,
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

#every 100,000 records
#transactions carry overhead
#if a transaction fails/ process dies
#the database should remain intact, just the last
#$self->commitEvery records will be missing
has commitEvery => (
  is => 'ro',
  init_arg => undef,
  default => 1000000,
  lazy => 1,
);

has overwrite => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
  lazy => 1,
);
#using state to make implicit singleton for the state that we want
#shared across all instances, without requiring exposing to public
#at the moment we generate a new environment for each $name
#because we can only have one writer per environment,
#across all threads
#and because there is some minor overhead with opening many named databases

sub BUILD {
  my $self = shift;

  say "Overwrite is" .  int($self->overwrite);
}

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
      #can't just use ternary that outputs 0 if not read only...
      flags => $self->read_only ? MDB_RDONLY | MDB_NOTLS | MDB_NOMETASYNC
        : MDB_NOTLS | MDB_NOMETASYNC,
      maxreaders => 1000,

      # More options
  });

  my $txn = $envs->{$name}->BeginTxn(); # Open a new transaction
 
  my $DB = $self->_openDB($txn);

  #set read mode
  # LMDB_File::_mydbflags($envs->{$name}, $dbi, 1);
  $txn->commit(); #now db is open

  # say MDB_RDONLY . " " . MDB_NOTLS . " " . MDB_NOMETASYNC;
  # $envs->{$name}->get_flags(my $flags);
  # say "flags are $flags";
  #unfortunately doesn't work if set after the fact
  #documentation is wrong, submitted Github issue: 
  # $envs->{$name}->set_flags(MDB_RDONLY,1);
  # if($self->read_only) {
  #   $envs->{$name}->set_flags(MDB_RDONLY,1);
  # }

  $dbis->{$name} = {
    env => $envs->{$name},
    dbi => $DB->dbi,
  };

  return $dbis->{$name};
}

sub _openDB {
  my ($self, $txn) = @_;
  my $DB;
  if(!$self->read_only) {
    $DB = $txn->OpenDB( #{    # Create a new database
      flags => MDB_CREATE 
    );
  }
  $DB = $txn->OpenDB();
  $DB->ReadMode(1);
  return $DB;
}

# I had wanted to use low-level transactions, but these seem to have
# rationale - hashes cannot really have duplicate keys; so, to circumvent this
# issue we'll check to see if there's data there at they key first, unpack it
# and add our new data to it and then store the merged data
# sub dbPut {
#   my ( $self, $chr, $pos, $href ) = @_;

#   my $dbi = $self->getDbi($chr);
#   my $txn = $dbi->{env}->BeginTxn();

#   $txn->put($dbi->{dbi}, $pos, encode_json($href) ); #overwrites existing values

#   $txn->commit();
# }

# # @param [HashRef[HashRef] ] $kvAref ; $key => {}, $key2 => {}
# sub dbPutBulk {
#   my ( $self, $chr, $posHref ) = @_;

#   my $dbi = $self->getDbi($chr);
#   my $txn = $dbi->{env}->BeginTxn();

#   my $cnt = 0;
#   for my $pos (keys %{$posHref} ) {
#     $txn->put($dbi->{dbi}, $pos, encode_json($posHref->{$pos} ) ); #overwrites existing values
#     $cnt++;
#     if($cnt > $self->commitEvery) {
#       $cnt = 0;
#       $txn->commit();
#       $txn = $dbi->{env}->BeginTxn();
#     }
#   }
  
#   $txn->commit();
# }

# sub dbPatch {
#   my ( $self, $chr, $pos, $newHref, $noOverwrite) = @_;

#   my $dbi = $self->getDbi($chr);
#   my $txn = $dbi->{env}->BeginTxn();
#   my $response;

#   my $previousJSON;
#   my $previousHref;

#   $txn->get($dbi->{dbi}, $pos, $previousJSON);
#   if($response) {
#     if($response == MDB_NOTFOUND) {
#       #nothing found
#     }
#   } else {
#     $self->tee_logger('warn', "DBI error: $response");
#   }

#   if($previousJSON) {
#     my ($featureID) = %$newHref;
#     $previousHref = decode_json($previousJSON);


#     if(!$self->overwrite) {
#       if(defined $previousHref->{$featureID} ) {
#         $txn->commit();
#         return;
#       }
#     }
#     $previousHref->{$featureID} = $newHref->{$featureID};
#     #much more robust, but I'm worried about performance, so trying alternative
#     #$previous_href = merge $previous_href, $posHref->{$pos}; #righthand merge
#   } else {
#     $previousHref = $newHref;
#   }

#   $txn->put($dbi->{dbi}, $pos, encode_json($previousHref) );

#   $txn->commit();
# }

#TODO: we should allow an array ref, more memory efficient
#Since we are using transactions, and have sync on commit enabled
#we know that if the feature name ($tokPkey) is found
#that the data is present
#Assumes that the posHref is
# {
#   position => {
#     feature_name => {
#       ...everything that belongs to feature_name
#     }
#   }
# }
# Since we make this assumption, we can just check if the feature exists
# and if it does, replace it (if we wish to overwrite);
sub dbPatchBulk {
  my ( $self, $chr, $posHref ) = @_;

  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->{env}->BeginTxn();
  my $response;

  my $cnt = 0;
  for my $pos (sort { $a <=> $b } keys %{$posHref} ) { #want sequential
    my $json; #zero-copy
    my $href;
    # say "pos is $pos";
    $response = $txn->get($dbi->{dbi}, $pos, $json);
    if($response) {
      if($response == MDB_NOTFOUND) {
        #nothing found
      }
    } else {
      $self->tee_logger('warn', "DBI error: $response");
    }

   # say "Last error is " . $LMDB_File::last_err;
    if($json) {
      my ($featureID) = %{$posHref->{$pos} };
      #can't modify json, read-only value, from memory map
      $href = decode_json($json);

      # say "previous href was";
      # p $previous_href;
      if(!$self->overwrite) {
        if(defined $href->{$featureID} ) {
          #say "defined $featureID, skipping";
          next;
        }
      }
      $href->{$featureID} = $posHref->{$pos}{$featureID};
      #much more robust, but I'm worried about performance, so trying alternative
      #$previous_href = merge $previous_href, $posHref->{$pos}; #righthand merge
    } else {
      $href = $posHref->{$pos};
    }
    
    $txn->put($dbi->{dbi}, $pos, encode_json($href) );

    $cnt++;
    if($cnt > $self->commitEvery) {
      $cnt = 0;
      $txn->commit();
      $txn = $dbi->{env}->BeginTxn();
    }
  }

  $txn->commit();
}

#Not currently in use
# we could use a cursor here, to allow non-whole chr insertion
# sub dbPatchBulkArray {
#   my ( $self, $chr, $posAref ) = @_;

#   my $dbi = $self->getDbi($chr);
#   my $txn = $dbi->{env}->BeginTxn();
#   my $cnt = 0;
#   #Expects 0 to end position (abs pos)
#   my $pos = 0; #so maybe cursor would be faster, not certain, is this still sequential?
#   my $cntFound = 0;

#   my $response;
#   for my $href (@$posAref) {
#     my $previous_href;
#     $LMDB_File::last_err = 0;
    
#     $response = $txn->get($dbi->{dbi}, $pos, $previous_href);
#     if($response) {
#       if($response == MDB_NOTFOUND) {
#         #nothing found
#       }
#     } else {
#       $self->tee_logger('warn', "DBI error: $response");
#     }

#    # say "Last error is " . $LMDB_File::last_err;
#     if($previous_href) {
#       $href = merge decode_json($previous_href), $href; #righthand merge
#     }

#     $txn->put($dbi->{dbi}, $pos, encode_json($href) );
#     $cnt++;
#     if($cnt > $self->commitEvery) {
#       $cnt = 0;
#       $txn->commit();
#       $txn = $dbi->{env}->BeginTxn();
#       if($self->debug) {
#         say "number entered : $pos";
#       }
#     }
#     $pos++;
#   }

#   if($self->debug) {
#     say "number items in aref: " . scalar @$posAref;
#     say "number found : $cntFound";
#     say "number entered : $pos";
#   }
 
#   $txn->commit();
# }

sub dbGet {
  my ( $self, $chr, $pos ) = @_;

  # the reason we need to check the existance of the db has to do with that we
  # allow non-existant file names to be used in creating the object and since
  # the creation of the _db attribute is done in a lazy way we may never need to
  # bother checking the file system or opening the databse.
  my $dbi = $self->getDbi($chr);
  my $txn = $dbi->{env}->BeginTxn();
  my $response;

  my $val;

  $response = $txn->get($dbi->{dbi}, $pos, $val);

  if($response) {
    if($response == MDB_NOTFOUND) {
      return;
    }
  } else {
    $self->tee_logger('warn', "DBI error: $response");
  }

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
