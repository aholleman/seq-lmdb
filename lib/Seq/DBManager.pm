use 5.10.0;
use strict;
use warnings;

package Seq::DBManager;

our $VERSION = '0.001';

# ABSTRACT: Manages Database connection
# VERSION

#TODO: Better errors; Seem to get bad perf if copy error after each db call

use Mouse 2;
with 'Seq::Role::Message';

use Data::MessagePack;
use LMDB_File qw(:all);
use Types::Path::Tiny qw/AbsPath/;
use Sort::XS;
use DDP;
use Hash::Merge::Simple qw/ merge /;
use Path::Tiny;
use Scalar::Util qw/looks_like_number/;

# We will maintain our own, internal database log for errors
use Cwd;
use Log::Fast;

# Most common error is "MDB_NOTFOUND" which isn't nec. bad.
$LMDB_File::die_on_err = 0;

######### Public Attributes
#0, 1, 2
has overwrite => ( is => 'rw', isa => 'Int', default => 0, lazy => 1);

# Flag for deleting tracks instead of inserting during patch* methods
has delete => (is => 'rw', isa => 'Bool', default => 0, lazy => 1);

has dry_run_insertions => (is => 'rw', isa => 'Bool', default => 0, lazy => 1);

# We expect the class to be used with one database directory only.
# It's formally possible to use others as well, so we allow consumer to decide
# By providing a way to set a singleton default
my $databaseDir;

# DBManager maintains its own, internal log, so that in a multi-user environment
# DBA can keep track of key errors
# TODO: Warning: cwd may fill up if left unchecked
my $internalLog = Log::Fast->new({
  path            => path( getcwd() )->child('dbManager-error.log')->stringify,
  pid             => $$,
});

#has database_dir => (is => 'ro', isa => 'Str', required => 1, default => sub {$databaseDir});

# Instance variable holding our databases; this way can be used 
# in environment where calling process never dies
# {
#   database_dir => {
#     env => $somEnv, dbi => $someDbi
#   }
# }

has _envs => (is => 'rw', init_arg => undef, default => sub{ {} });

# Can call as class method (DBManager->setDefaultDatabaseDir), or as instance method
sub setGlobalDatabaseDir {
  #say "setting database dir to " . (@_ == 2 ? $_[1] : $_[0]);
  $databaseDir = @_ == 2 ? $_[1] : $_[0];
}

# Read only state is shared across all instances. Lock-less reads are dangerous
state $dbReadOnly;
# Can call as class method (DBManager->setReadOnly), or as instance method
sub setReadOnly {
  $dbReadOnly = @_ == 2 ? $_[1] : $_[0];
}

sub BUILD {
  my $self = shift;

  if(!$databaseDir) {
    $self->log('fatal', "DBManager requires databaseDir");
  }

  my $dbDir = path($databaseDir)->absolute();

  if(!$dbDir->exists) { $dbDir->mkpath; }
  if(!$dbDir->is_dir) { $self->log('fatal', 'database_dir not a directory'); }
};

# Our packing function
my $mp = Data::MessagePack->new();
$mp->prefer_integer(); #treat "1" as an integer, save more space

################### DB Read, Write methods ############################

sub dbRead {
  #my ($self, $chr, $posAref) = @_;
  #== $_[0], $_[1], $_[2] (don't assign to avoid copy)
  my $db = $_[0]->_getDbi($_[1]);

  if(!$db) {
    if(!$dbReadOnly) {
      return $_[0]->_errorWithCleanup("Couldn't open database $_[1] in dbRead");
    }

    return ref $_[2] ? [] : undef;
  }

  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  my @out;
  my $json;

  #will return a single value if we were passed one value
  if(!ref $_[2] ) {
    $txn->get($dbi, $_[2], $json);
      
    $txn->commit();

    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND ) {
      return $_[0]->_errorWithCleanup("dbRead LMDB error $LMDB_File::last_err");
    }

    $LMDB_File::last_err = 0;

    return $json ? $mp->unpack($json) : undef;
  }

  #or an array of values, in order
  for my $pos ( @{ $_[2] } ) {
    $txn->get($dbi, $pos, $json);
    
    if(!$json) {
      if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
        return $_[0]->_errorWithCleanup("dbRead LMDB error $LMDB_File::last_err");
      }

      #we return exactly the # of items, and order, given to us
      #but 
      push @out, undef;
      next;
    }
    push @out, $mp->unpack($json);
  }
  
  $txn->commit();

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    return $_[0]->_errorWithCleanup("dbRead LMDB error after loop: $LMDB_File::last_err");
  }

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  #will return a single value if we were passed one value
  return \@out;
}

#Assumes that the posHref is
# {
#   position => {
#     feature_name => {
#       ...everything that belongs to feature_name
#     }
#   }
# }

# Method to write one position in the database, as a hash
# $pos can be any string, identifies a key within the kv database
# dataHref should be {someTrackName => someData} that belongs at $chr:$pos
sub dbPatchHash {
  my ( $self, $chr, $pos, $dataHref, $overrideOverwrite, $mergeFunc, $deleteOverride) = @_;

  if(ref $dataHref ne 'HASH') {
    return $self->_errorWithCleanup("dbPatchHash requires a 1-element hash of a hash");
  }

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  my $overwrite = $overrideOverwrite || $self->overwrite;
  my $delete = $deleteOverride || $self->delete;

  # Get existing data
  my $json; 
  $txn->get($dbi, $pos, $json);
  # Commit to avoid db inflation
  $txn->commit();

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    return $self->_errorWithCleanup("dbPatchHash LMDB error $LMDB_File::last_err");
  }

  # If deleting, and there is no existing data, nothing to do
  if(!$json && $delete) { return; }

  if($json) {
    my $href = $mp->unpack($json);
    
    my ($trackKey, $trackValue) = %{$dataHref};

    if(!defined $trackKey || ref $trackKey ) {
      return $self->_errorWithCleanup("dbPatchHash requires scalar trackKey");
    }

    if(!defined $trackValue) {
      return $self->_errorWithCleanup("dbPatchHash requires trackValue");
    }

    if( defined $href->{$trackKey} ) {
      # Deletion and insertion are mutually exclusive
      if($delete) {
        delete $href->{$trackKey};
      } elsif(defined $mergeFunc) {
        $href->{$trackKey} = &$mergeFunc($chr, $pos, $href->{$trackKey}, $trackValue);
      } else {
        # If not overwriting, nothing to do, return from function
        if(!$overwrite) { return; }

        # Merge with righthand hash taking precedence, https://ideone.com/SBbfYV
        $href = merge $href, $dataHref;
      }
    } else {
      $href->{$trackKey} = $trackValue;
    }

    # Modify the stack in place, can't just set $dataHref
    $_[3] = $href;
  }

  #Else we don't modify dataHref, and it gets passed on as is to dbPut
  
  #reset the calls error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
  
  return &dbPut;
}
  
# Method to write multiple positions in the database, as arrays
# The behavior of dbPatchBulkArray is as follows:
# 1. If no data at all is found at a position, some data is added
# 2. If the key we're trying to insert data for at that pos doesn't exist, it is added
# with its corresponding value
# 3. If the key is already present at that position, we need to show that there
# are multiple entries for this key
# To do that, we can convert the value into an array. If the value is already an
sub dbPatchBulkArray {
  my ( $self, $chr, $posHref, $overrideOverwrite, $mergeFunc, $deleteOverride) = @_;

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  #https://ideone.com/Y0C4tX
  my $overwrite = $overrideOverwrite || $self->overwrite;
  my $delete = $deleteOverride || $self->delete;

  # We'll use goto to get to dbPutBulk, so store this in stack
  my @allPositions = @{ xsort([keys %$posHref]) };

  for my $pos ( @allPositions ) {
    if(ref $posHref->{$pos} ne 'HASH') {
      return $self->_errorWithCleanup("dbPatchBulkAsArray requires a 1-element hash of a hash");
    }

    my ($trackIndex, $trackValue) = %{ $posHref->{$pos} };
    
    if(!defined $trackIndex || ! looks_like_number($trackIndex) ) {
      return $self->_errorWithCleanup("dbPatchBulkAsArray requies numeric trackIndex");
    }

    # Undefined values allowed
    
    #zero-copy
    $txn->get($dbi, $pos, my $json);

    #trigger this only if json isn't found, save on many if calls
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      return $self->_errorWithCleanup("dbPatchBulk LMDB error $LMDB_File::last_err");
    }

    my $aref = defined $json ? $mp->unpack($json) : [];

    if(defined $aref->[$trackIndex]) {
      if($delete) {
        $aref->[$trackIndex] = undef;
        $posHref->{$pos} = $aref;
      }elsif($mergeFunc) {
        $aref->[$trackIndex] = &$mergeFunc($chr, $pos, $trackIndex, $aref->[$trackIndex], $trackValue);
        $posHref->{$pos} = $aref;
      }elsif($overwrite) {
        $aref->[$trackIndex] = $trackValue;
        $posHref->{$pos} = $aref;
      } else {
        # if the position is defined, and we don't want to overwrite the data,
        # remove this position from list of those we will put into the db
        delete $posHref->{$pos};
      }
    } elsif(!$delete) {
      # Either $json not defined ($aref empty) or trackIndex not defined
      # Assigning an element to the array auto grows it
      #https://ideone.com/Wzjmrl
      $aref->[$trackIndex] = $trackValue;
      $posHref->{$pos} = $aref;
    } else {
      # We want to delete this position, which certainly means we're not inserting it
      delete $posHref->{$pos};
    }
  }

  $txn->abort();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  return $self->dbPutBulk($chr, $posHref, \@allPositions);
}

sub dbPut {
  my ( $self, $chr, $pos, $data) = @_;

  if($self->dry_run_insertions) {
    return $self->log('info', "Received dry run request: chr:pos $chr:$pos");
    #say "Received dry run request: chr:pos $chr:$pos";
    #p $data;
    #return;
  }

  if(!defined $pos) {
    return $self->log('warn', "dbPut requires position");
  }

  if(!defined $data) {
    return $self->log('warn', "dbPut: attepmting to insert undefined data @ $chr:$pos, skipping");
  }

  my $db = $self->_getDbi($chr);
  my $txn = $db->{env}->BeginTxn();

  $txn->put($db->{dbi}, $pos, $mp->pack( $data ) );

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_KEYEXIST) {
    return $self->_errorWithCleanup("dbPut LMDB error: $LMDB_File::last_err");
  }

  $txn->commit();
  
  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

sub dbPutBulk {
  my ( $self, $chr, $posHref, $passedSortedPosAref) = @_;

  if($self->dry_run_insertions) {
    return $self->log('info', "Received dry run request: chr $chr for " . (scalar keys %{$posHref} ) . " positions" );
    #say "Received dry run request";
    #p $posHref;
    #return;
  }

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn();

  #Enforce putting in ascending lexical or numerical order
  my $sortedPosAref = $passedSortedPosAref || xsort( [keys %{$posHref} ] );
  
  for my $pos (@$sortedPosAref) {
    # User may have passed a sortedPosAref that has more values than the 
    # $posHref, to avoid a second (large) sort
    if(!exists $posHref->{$pos}) { next; }

    $txn->put($dbi, $pos, $mp->pack( $posHref->{$pos} ) );

    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_KEYEXIST) {
      return $self->_errorWithCleanup("dbPutBulk LMDB error: $LMDB_File::last_err");
    }
  }

  $txn->commit();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

sub dbDelete {
  my ( $self, $chr, $pos) = @_;

  if($self->dry_run_insertions) {
    return $self->log('info', "Received dry run request to delete: chr:pos $chr:$pos");
  }

  if(!defined $chr || !defined $pos) {
    return $self->log('warn', "dbDelete requires chr and position");
  }

  my $db = $self->_getDbi($chr);
  my $txn = $db->{env}->BeginTxn();

  $txn->del($db->{dbi}, $pos);

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_KEYEXIST) {
    return $self->_errorWithCleanup("dbPut LMDB error: $LMDB_File::last_err");
  }

  $txn->commit();
  
  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

#TODO: check if this works
sub dbGetNumberOfEntries {
  my ( $self, $chr ) = @_;

  #get database, but don't create it if it doesn't exist
  my $db = $self->_getDbi($chr,1);

  return $db ? $db->{env}->stat->{entries} : 0;
}

#cursor version
sub dbReadAll {
  #my ( $self, $chr ) = @_;
  #==   $_[0]   $_[1]
  my $db = $_[0]->_getDbi($_[1]);

  if(!$db) {
    if(!$dbReadOnly) {
      return $_[0]->_errorWithCleanup("Couldn't open database $_[1] in dbReadAll");
    }

    return {};
  }

  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  #unfortunately if we close the transaction, cursors stop working
  #a limitation of the current API
  #and since dbi wouldn't be available to the rest of this package unless
  #that transaction was comitted
  #we need to re-open the database for dbReadAll transactions
  my $DB = $txn->OpenDB();
  #https://metacpan.org/pod/LMDB_File
  #avoids memory copy on get operation
  $DB->ReadMode(1);

  my $cursor = $DB->Cursor;

  my ($key, $value, %out);
  while(1) {
    $cursor->get($key, $value, MDB_NEXT);
      
    #because this error is generated right after the get
    #we want to capture it before the next iteration 
    #hence this is not inside while( )
    if($LMDB_File::last_err == MDB_NOTFOUND) {
      last;
    }

    if($LMDB_FILE::last_err) {
      return $_[0]->_errorWithCleanup("dbReadAll LMDB error $LMDB_FILE::last_err");
    }

    $out{$key} = $mp->unpack($value);
  }

  $txn->commit();

  if($LMDB_FILE::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    return $_[0]->_errorWithCleanup("dbReadAll LMDB error after loop: $LMDB_FILE::last_err");
  }

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  return \%out;
}

#to store any records
#For instance, here we can store our feature name mappings, our type mappings
#whether or not a particular track has completed writing, etc
state $metaDbNamePart = '_meta';

#We allow people to update special "Meta" databases
#The difference here is that for each $databaseName, there is always
#only one meta database. Makes storing multiple meta documents in a single
#meta collection easy
#For example, users may want to store field name mappings, how many rows inserted
#whether building the database was a success, and more
sub dbReadMeta {
  my ( $self, $databaseName, $metaKey ) = @_;
  
  #dbGet returns an array only when it's given an array
  #so for a single "position"/key (in our case $metaKey)
  #only a single value should be returned (whether a hash, or something else
  # based on caller's expectations)
  return $self->dbRead($databaseName . $metaDbNamePart, $metaKey, 1);
}

sub dbDeleteMeta {
  my ( $self, $databaseName, $metaKey ) = @_;
  
  #dbDelete returns nothing
  return $self->dbDelete($databaseName . $metaDbNamePart, $metaKey);
}

#@param <String> $databaseName : whatever the user wishes to prefix the meta name with
#@param <String> $metaKey : this is our "position" in the meta database
 # a.k.a the top-level key in that meta database, what type of meta data this is 
#@param <HashRef|Scalar> $data : {someField => someValue} or a scalar value
sub dbPatchMeta {
  my ( $self, $databaseName, $metaKey, $data) = @_;
  
  # If the user treats this metaKey as a scalar value, overwrite whatever was there
  if(!ref $data) {
    $self->dbPut($databaseName . $metaDbNamePart, $metaKey, $data);
    return;
  }

  # Pass 1 to merge $data with whatever was kept at this metaKey
  $self->dbPatchHash($databaseName . $metaDbNamePart, $metaKey, $data, 1);

  return;
}

sub _getDbi {
  # Exists and not defined, because in read only database we may discover
  # that some chromosomes don't have any data (example: hg38 refSeq chrM)
  if ( exists $_[0]->_envs->{$_[1]} ) {
    return $_[0]->_envs->{$_[1]};
  }
  
  #   $_[0]  $_[1], $_[2]
  # Don't create used by dbGetNumberOfEntries
  my ($self, $name, $dontCreate) = @_;

  # $self->log('debug', "received request to make database for $databaseDir $name");
  
  my $dbPath = path($databaseDir)->child($name);

  #create database unless dontCreate flag set
  if(!$dontCreate && !$dbReadOnly) {
    if(!$dbPath->child($name)->is_dir) {
      $dbPath->child($name)->mkpath;
    }
  }

  $dbPath = $dbPath->stringify;

  my $flags;
  if($dbReadOnly) {
    $flags = MDB_NOTLS | MDB_NOMETASYNC | MDB_NOLOCK | MDB_NOSYNC | MDB_RDONLY;
  } else {
    $flags = MDB_NOTLS | MDB_NOMETASYNC;
  }

  my $env = LMDB::Env->new($dbPath, {
    mapsize => 128 * 1024 * 1024 * 1024, # Plenty space, don't worry
    #maxdbs => 20, # Some databases
    mode   => 0600,
    #can't just use ternary that outputs 0 if not read only...
    #MDB_RDONLY can also be set per-transcation; it's just not mentioned 
    #in the docs
    flags => $flags,
    maxdbs => 1, # Some databases; else we get a MDB_DBS_FULL error (max db limit reached)
  });

  if(! $env ) {
    if(!$dbReadOnly) {
      return $self->_errorWithCleanup("Failed to create environment $name for $databaseDir beacuse of $LMDB_File::last_err");
    }

    # If dbReadOnly, won't be able to open the database, but this isn't a problem
    $LMDB_File::last_err = 0;

    $self->_envs->{$name} = undef;

    return $self->_envs->{$name};
  }

  my $txn = $env->BeginTxn();
  
  my $DB = $txn->OpenDB();

  # ReadMode 1 gives memory pointer for perf reasons, not safe
  $DB->ReadMode(1);

  # Now db is open
  $txn->commit();

  if($LMDB_File::last_err) {
    return $self->_errorWithCleanup("Failed to open database $name for $databaseDir beacuse of $LMDB_File::last_err");
  }

  $self->_envs->{$name} = {env => $env, dbi => $DB->dbi};

  #say "made database $name for " .$databaseDir;

  return $self->_envs->{$name};
}


sub cleanUp {
  my $self = shift;
  
  foreach (keys %{ $self->_envs} ) {
    # Check defined because database may be empty (and will be stored as undef)
    if(defined $self->_envs->{$_} ) {
      $self->_envs->{$_}{env}->Clean();
    }
  }

  # Break reference to the environment; should cause the object DESTROY method
  # to be called; unless some bad consumer has made references to this class
  $self->_envs({});
}

# For now, we'll throw the error, until program is changed to expect error/success
# status from functions
sub _errorWithCleanup {
  my ($self, $msg) = @_;

  $self->cleanUp();
  $internalLog->ERR($msg);
  # Reset error message, not sure if this is the best way
  $LMDB_File::last_err = 0;
  return $self->log('fatal', $msg);
}

# Get a transaction for dbRead; often we may use the database in read-only
# mode
sub _getDbReadTx {
  # $self, $chr
  # $_[0], $_[1];
  my $env = $_[0]->_envs->{$_[1]};

  if($dbReadOnly) {
    if(defined $env->{readOnlyTx}) {
      $env->{readOnlyTx}->renew();
    } else {
      $env->{readOnlyTx} = $env->BeginTxn(MDB_RDONLY);
      # probably unnecessary
      $env->{readOnlyTx}->reset();
    }

    return ( $env->{dbi}, $env->{readOnlyTx} );
  }
}

__PACKAGE__->meta->make_immutable;

1;

########### hash-based method ##############

# Write database entries in bulk
# Expects one track per call ; each posHref should have {pos => {trackName => trackData} }
# @param <HashRef> $posHref : form of {pos => {trackName => trackData} }, modified in place
# sub dbPatchBulkHash {
#   my ( $self, $chr, $posHref, $overrideOverwrite) = @_;
    
#   my $db = $self->_getDbi($chr);
#   my $dbi = $db->{dbi}; 
#   #separate read and write transacions, hopefully helps with db inflation due to locks
#   my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

#   #https://ideone.com/Y0C4tX
#   my $overwrite = $overrideOverwrite || $self->overwrite;

#   for my $pos ( keys %$posHref ) {
#     if(ref $posHref->{$pos} ne 'HASH') {
#       $self->log('fatal', "dbPatchBulkAsArray requires a 1-element hash of a hash");
#     }

#     my ($trackIndex) = %{ $posHref->{$pos} };
    
#     my $json; #zero-copy
#     $txn->get($dbi, $pos, $json);

#     #trigger this only if json isn't found, save on many if calls
#     if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
#       $self->log('warn', "dbPatchBulk error" . $LMDB_File::last_err);
#     }

#     if($json) {
#       #can't modify $json, read-only value, from memory map
#       my $href = $mp->unpack($json);

#       if(defined $href->{$trackIndex} && !$overwrite) {
#         #skip this position (we pass posHref to dbPutBulk)
#         delete $posHref->{$pos};
#         next;
#       }

#       if($overwrite == 1) {
#         $posHref->{$pos} = merge( $href, $posHref->{$pos} );
#         next;
#       }

#       #overwrite > 1
#       $href->{$trackIndex} = $posHref->{$pos}{$trackIndex};
#       #this works because it modifies the stack's reference
#       $posHref->{$pos} = $href;
#       next;
#     }

#     #posHref is unchanged, we write it as is
#     next;
#   }

#   $txn->commit();

#   #reset the class error variable
#   $LMDB_File::last_err = 0;

#   #Then write the new data, re-using the stack for efficiency
#   goto &dbPutBulk;
# }

### WIP NOT USED CURRENTLY ####
# Potentially valuable numerical approach to dbReadAll

#if we expect numeric keys we could get first, last and just $self->dbRead[first .. last]
#but we don't always expect keys to be numeric
#and am not certain this is meaningfully slower
#only difference is overhead for checking whether txn is alive in LMDB_File

#TODO: Not sure which is faster, the cursor version or the numerical one

# sub dbReadAll {
#   my ( $self, $chr ) = @_;

#   my $db = $self->_getDbi($chr);
#   my $dbi = $db->{dbi};
#   my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

#   #unfortunately if we close the transaction, cursors stop working
#   #a limitation of the current API
#   #and since dbi wouldn't be available to the rest of this package unless
#   #that transaction was comitted
#   #we need to re-open the database for dbReadAll transactions
#   #my $DB = $self->_openDB($txn);
#   #my $cursor = $DB->Cursor;

#   my ($key, %out, $json);

#   #assumes all keys are numeric
#   $key = 0;
#   while(1) {
#     $txn->get($dbi, $key, $json);
#     #because this error is generated right after the get
#     #we want to capture it before the next iteration 
#     #hence this is not inside while( )
#     if($LMDB_File::last_err == MDB_NOTFOUND) {
#       last;
#     }
#     #perl always gives us a reference to the item in the array
#     #so we can just re-assign it
#     $out{$key} = $mp->unpack($json);
#     $key++
#   }
#     #$cursor->get($key, $value, MDB_NEXT);
      
#   $txn->commit();
#   #reset the class error variable, to avoid crazy error reporting later
#   $LMDB_File::last_err = 0;

#   return \%out;
# }

# @param $nameOfKeyToDelete
# sub dbDeleteKeys {
#   my ( $self, $chr, $nameOfKeyToDelete) = @_;
  
#   my $db = $self->_getDbi($chr);
#   my $dbi = $db->{dbi};
#   my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

#   my $DB = $txn->OpenDB();
#   #https://metacpan.org/pod/LMDB_File
#   #avoids memory copy on get operation
#   $DB->ReadMode(1);

#   my $cursor = $DB->Cursor;

#   my @err;

#   my ($key, $value, %out);
#   while(1) {
#     $cursor->get($key, $value, MDB_NEXT);

#     #because this error is generated right after the get
#     #we want to capture it before the next iteration 
#     #hence this is not inside while( )
#     if($LMDB_File::last_err == MDB_NOTFOUND) {
#       last;
#     }

#     if($LMDB_FILE::last_err) {
#       $_[0]->log('warn', 'found non MDB_FOUND LMDB_FILE error in dbReadAll: '.
#         $LMDB_FILE::last_err );
#       push @err, $LMDB_FILE::last_err;
#       $LMDB_FILE::last_err = 0;
#       next;
#     }

#     $txn->commit();
#   }
# }

# Not in use cursor
#TODO: Use cursor for txn2, don't commit every, may be faster
#and write single commit size 
#we don't care terribly much about performance here, this happens once in a great while,
#so we use our public function dbPutBulk
# sub dbWriteCleanCopy {
#   #for every... $self->dbPutBulk
#   #dbRead N records, divide dbGetLength by some reasonable size, like 1M
#   my ( $self, $chr ) = @_;

#   if($self->dbGetNumberOfEntries($chr) == 0) {
#     $self->log('fatal', "Database $chr is empty, canceling clean copy command");
#   }

#   my $db = $self->_getDbi($chr);
#   my $dbi = $db->{dbi};
#   my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

#   my $db2 = $self->_getDbi("$chr\_clean_copy");
#   my $dbi2 = $db2->{dbi};
  

#   my $DB = $txn->OpenDB();
#   #https://metacpan.org/pod/LMDB_File
#   #avoids memory copy on get operation
#   $DB->ReadMode(1);

#   my $cursor = $DB->Cursor;

#   my ($key, $value, %out);
#   while(1) {
#     $cursor->get($key, $value, MDB_NEXT);

#     #because this error is generated right after the get
#     #we want to capture it before the next iteration 
#     #hence this is not inside while( )
#     if($LMDB_File::last_err == MDB_NOTFOUND) {
#       last;
#     }

#     if($LMDB_FILE::last_err) {
#       $_[0]->log('warn', 'found non MDB_FOUND LMDB_FILE error in dbReadAll: '.
#         $LMDB_FILE::last_err );
#       next;
#     }

#     my $txn2 = $db2->{env}->BeginTxn();
#       $txn2->put($dbi2, $key, $value);
      
#       if($LMDB_FILE::last_err) {
#         $self->log('warn', "LMDB_FILE error adding $key: " . $LMDB_FILE::last_err );
#         next;
#       }
#     $txn2->commit();

#     if($LMDB_FILE::last_err) {
#       $self->log('warn', "LMDB_FILE error adding $key: " . $LMDB_FILE::last_err );
#     }
#   }

#   $txn->commit();

#   if($LMDB_File::last_error == MDB_NOTFOUND) {
#     my $return = system("mv $db->{path} $db->{path}.bak");
#     if(!$return) {
#       $return = system("mv $db2->{path} $db->{path}");

#       if(!$return) {
#         $return = system("rm -rf $db->{path}.bak");
#         if($return) {
#           $self->log('warn', "Error deleting $db->{path}.bak");
#         }
#       } else {
#         $self->log('fatal', "Error moving $db2->{path} to $db->{path}");
#       }
#     } else {
#       $self->log('fatal', "Error moving $db->{path} to $db->{path}.bak");
#     }
#   } else {
#     $self->log('fatal', "Error copying the $chr database: $LMDB_File::last_error");
#   }
#   #reset the class error variable, to avoid crazy error reporting later
#   $LMDB_File::last_err = 0;
# }

# Works, but not currently used; this wastes a bunch of space, for any track
# that doesn't cover a particular position.

# sub dbPatchBulk {
#   my ( $self, $chr, $posHref, $overrideOverwrite) = @_;
    
#   my $db = $self->_getDbi($chr);
#   my $dbi = $db->{dbi}; 
#   #separate read and write transacions, hopefully helps with db inflation due to locks
#   my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

#   #https://ideone.com/Y0C4tX
#   my $overwrite = $overrideOverwrite || $self->overwrite;

#   for my $pos ( keys %$posHref ) {
#     if(ref $posHref->{$pos} ne 'HASH') {
#       $self->log('fatal', "dbPatchBulkAsArray requires a 1-element hash of a hash");
#     }

#     my ($trackIndex) = %{ $posHref->{$pos} };
    
#     my $json; #zero-copy
#     $txn->get($dbi, $pos, $json);

#     #trigger this only if json isn't found, save on many if calls
#     if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
#       $self->log('warn', "dbPatchBulk error" . $LMDB_File::last_err);
#     }

#     if($json) {
#       #can't modify $json, read-only value, from memory map
#       my $href = $mp->unpack($json);

#       if(defined $href->{$trackIndex} && !$overwrite) {
#         #skip this position (we pass posHref to dbPutBulk)
#         delete $posHref->{$pos};
#         next;
#       }

#       if($overwrite == 1) {
#         $posHref->{$pos} = merge( $href, $posHref->{$pos} );
#         next;
#       }

#       #overwrite > 1
#       $href->{$trackIndex} = $posHref->{$pos}{$trackIndex};
#       #this works because it modifies the stack's reference
#       $posHref->{$pos} = $href;
#       next;
#     }

#     #posHref is unchanged, we write it as is
#     next;
#   }

#   $txn->commit();

#   #reset the class error variable
#   $LMDB_File::last_err = 0;

#   #Then write the new data, re-using the stack for efficiency
#   goto &dbPutBulk;
# }