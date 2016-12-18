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
####################### Static Properties ############################
state $databaseDir;
# Each process should open each environment only once.
state $envs = {};
# Read only state is shared across all instances. Lock-less reads are dangerous
state $dbReadOnly;

# Can call as class method (DBManager->setDefaultDatabaseDir), or as instance method
sub setGlobalDatabaseDir {
  #say "setting database dir to " . (@_ == 2 ? $_[1] : $_[0]);
  $databaseDir = @_ == 2 ? $_[1] : $_[0];
}

# Can call as class method (DBManager->setReadOnly), or as instance method
sub setReadOnly {
  $dbReadOnly = @_ == 2 ? $_[1] : $_[0];
}

# Prepares the class for consumption; should be run before the program can fork
# To ensure that all old data is cleared, if executing from a long-running process
sub initialize {
  cleanUp();

  $databaseDir = undef;
  $envs = {};
  $dbReadOnly = undef;
}

sub BUILD {
  my $self = shift;

  if(!$databaseDir) {
    $self->_errorWithCleanup("DBManager requires databaseDir");
  }

  my $dbDir = path($databaseDir)->absolute();

  if(!$dbDir->exists) { $dbDir->mkpath; }
  if(!$dbDir->is_dir) { $self->_errorWithCleanup('database_dir not a directory'); }
};

# Our packing function
my $mp = Data::MessagePack->new();
$mp->prefer_integer(); #treat "1" as an integer, save more space

################### DB Read, Write methods ############################
# Unsafe for $_[2] ; will be modified if an array is passed
sub dbReadOne {
  #my ($self, $chr, $posAref) = @_;
  #== $_[0], $_[1], $_[2] (don't assign to avoid copy)
  my $db = $_[0]->_getDbi($_[1]);

  if(!$db) {
    return undef;
  }

  # my $dbi = $db->{dbi};
  # my $txn = $db->{env}->BeginTxn(MDB_RDONLY);
  if(!$db->{db}->Alive) {
    $db->{db}->Txn = $db->{env}->BeginTxn(MDB_RDONLY);
  }

  my $txn = $db->{db}->Txn;

  $txn->get($db->{dbi}, $_[2], my $json);

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND ) {
    $_[0]->_errorWithCleanup("dbRead LMDB error $LMDB_File::last_err");
    return;
  }

  $LMDB_File::last_err = 0;

  return $json ? $mp->unpack($json) : undef; 
}

# Unsafe for $_[2] ; will be modified if an array is passed
sub dbRead {
  #my ($self, $chr, $posAref) = @_;
  #== $_[0], $_[1], $_[2] (don't assign to avoid copy)
  if(!ref $_[2]) {
    goto &dbReadOne;
  }

  my $db = $_[0]->_getDbi($_[1]);

  if(!$db) {
    return [];
  }

  # my $dbi = $db->{dbi};
  # my $txn = $db->{env}->BeginTxn(MDB_RDONLY);
  if(!$db->{db}->Alive) {
    $db->{db}->Txn = $db->{env}->BeginTxn(MDB_RDONLY);
  }

  my $txn = $db->{db}->Txn;

  my $json;

  # my @out;
  #or an array of values, in order
  #CAREFUL: modifies the array
  for my $pos (@{ $_[2] }) {
    $txn->get($db->{dbi}, $pos, $json);
    
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $_[0]->_errorWithCleanup("dbRead LMDB error $LMDB_File::last_err");
      return;
    }

    if(!$json) {
      #we return exactly the # of items, and order, given to us
      $pos = undef;
      next;
    }

    $pos = $mp->unpack($json);
  }
  
  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    $_[0]->_errorWithCleanup("dbRead LMDB error after loop: $LMDB_File::last_err");
    return;
  }
  
  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  #will return a single value if we were passed one value
  return $_[2];#\@out;
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
    $self->_errorWithCleanup("dbPatchHash requires a 1-element hash of a hash");
    return;
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

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    $self->_errorWithCleanup("dbPatchHash LMDB error during get: $LMDB_File::last_err");
    return;
  }

  my $err = $txn->abort();

  if($err) {
    $self->_errorWithCleanup("dbPatchHash LMDB error during get: $err");
  }

  # If deleting, and there is no existing data, nothing to do
  if(!$json && $delete) { return; }

  if($json) {
    my $href = $mp->unpack($json);
    
    my ($trackKey, $trackValue) = %{$dataHref};

    if(!defined $trackKey || ref $trackKey ) {
      $self->_errorWithCleanup("dbPatchHash requires scalar trackKey");
      return;
    }

    if(!defined $trackValue) {
      $self->_errorWithCleanup("dbPatchHash requires trackValue");
      return;
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
      $self->_errorWithCleanup("dbPatchBulkAsArray requires a 1-element hash of a hash");
      return;
    }

    my ($trackIndex, $trackValue) = %{ $posHref->{$pos} };
    
    if(!defined $trackIndex || ! looks_like_number($trackIndex) ) {
      $self->_errorWithCleanup("dbPatchBulkAsArray requies numeric trackIndex");
      return;
    }

    # Undefined values allowed
    
    #zero-copy
    $txn->get($dbi, $pos, my $json);

    #trigger this only if json isn't found, save on many if calls
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $self->_errorWithCleanup("dbPatchBulk LMDB error $LMDB_File::last_err");
      return;
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

  my $err = $txn->abort();

  if($err) {
    $self->_errorWithCleanup("dbPatchBulkArray LMDB error at end: $err");
    return;
  }

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  return $self->dbPutBulk($chr, $posHref, \@allPositions);
}

sub dbPut {
  my ( $self, $chr, $pos, $data) = @_;

  if($self->dry_run_insertions) {
    $self->log('info', "Received dry run request: chr:pos $chr:$pos");
    return;
  }

  if(!defined $pos) {
    $self->log('warn', "dbPut requires position");
    return;
  }

  if(!defined $data) {
    $self->log('warn', "dbPut: attepmting to insert undefined data @ $chr:$pos, skipping");
    return;
  }

  my $db = $self->_getDbi($chr);
  my $txn = $db->{env}->BeginTxn();

  $txn->put($db->{dbi}, $pos, $mp->pack( $data ) );

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_KEYEXIST) {
    $self->_errorWithCleanup("dbPut LMDB error: $LMDB_File::last_err");
    return;
  }

  my $err = $txn->commit();

  if($err) {
    $self->_errorWithCleanup("dbPut LMDB error at end: $err");
  }
  
  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

sub dbPutBulk {
  my ( $self, $chr, $posHref, $passedSortedPosAref) = @_;

  if($self->dry_run_insertions) {
    $self->log('info', "Received dry run request: chr $chr for " . (scalar keys %{$posHref} ) . " positions" );
    return;
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
      $self->_errorWithCleanup("dbPutBulk LMDB error: $LMDB_File::last_err");
      return;
    }
  }

  my $err = $txn->commit();

  if($err) {
    $self->_errorWithCleanup("dbPutBulk LMDB error at end: $err");
  }

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
    return {};
  }

  if(!$db->{db}->Alive) {
    $db->{db}->Txn = $db->{env}->BeginTxn(MDB_RDONLY);
  }

  # LMDB::Cursor::open($txn, $db->{dbi}, my $cursor);
  my $cursor = $db->{db}->Cursor;

  my ($key, $value, %out);
  while(1) {
    $cursor->get($key, $value, MDB_NEXT);
      
    #because this error is generated right after the get
    #we want to capture it before the next iteration 
    #hence this is not inside while( )
    if($LMDB_File::last_err == MDB_NOTFOUND) {
      $LMDB_FILE::last_err = 0;
      last;
    }

    if($LMDB_FILE::last_err) {
      $_[0]->_errorWithCleanup("dbReadAll LMDB error $LMDB_FILE::last_err");
      return;
    }

    $out{$key} = $mp->unpack($value);
  }

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    $_[0]->_errorWithCleanup("dbReadAll LMDB error at end: $LMDB_File::last_err");
    return;
  }

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  return \%out;
}

sub dbDelete {
  my ( $self, $chr, $pos) = @_;

  if($self->dry_run_insertions) {
    $self->log('info', "Received dry run request to delete: chr:pos $chr:$pos");
    return;
  }

  if(!defined $chr || !defined $pos) {
    $self->_errorWithCleanup("dbDelete requires chr and position");
    return;
  }

  my $db = $self->_getDbi($chr);
  my $txn = $db->{env}->BeginTxn();

  # Error with LMDB_File api, means $data is required as 3rd argument,
  # even if it is undef
  $txn->del($db->{dbi}, $pos, undef);

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    $self->_errorWithCleanup("dbDelete LMDB error: $LMDB_File::last_err");
    return;
  }

  my $err = $txn->commit();

  if($err) {
    $self->_errorWithCleanup("dbDelete error at end: $err");
    return;
  }
  
  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
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
  return $self->dbReadOne($databaseName . $metaDbNamePart, $metaKey);
}

#@param <String> $databaseName : whatever the user wishes to prefix the meta name with
#@param <String> $metaKey : this is our "position" in the meta database
 # a.k.a the top-level key in that meta database, what type of meta data this is 
#@param <HashRef|Scalar> $data : {someField => someValue} or a scalar value
sub dbPatchMeta {
  my ( $self, $databaseName, $metaKey, $data ) = @_;
  
  # If the user treats this metaKey as a scalar value, overwrite whatever was there
  if(!ref $data) {
    $self->dbPut($databaseName . $metaDbNamePart, $metaKey, $data);
    return;
  }

  # Pass 1 to merge $data with whatever was kept at this metaKey
  $self->dbPatchHash($databaseName . $metaDbNamePart, $metaKey, $data, 1);

  return;
}

sub dbDeleteMeta {
  my ( $self, $databaseName, $metaKey ) = @_;

  #dbDelete returns nothing
  $self->dbDelete($databaseName . $metaDbNamePart, $metaKey);
  return;
}

sub _getDbi {
  # Exists and not defined, because in read only database we may discover
  # that some chromosomes don't have any data (example: hg38 refSeq chrM)
  if ( exists $envs->{$_[1]} ) {
    return $envs->{$_[1]};
  }
  
  #   $_[0]  $_[1], $_[2]
  # Don't create used by dbGetNumberOfEntries
  my ($self, $name, $dontCreate) = @_;

  my $dbPath = path($databaseDir)->child($name);

  # Create the database, only if that is what is intended
  if(!$dbPath->is_dir) {
    # If dbReadOnly flag set, this database will NEVER be created during the 
    # current execution cycle
    if($dbReadOnly) {
      $envs->{$name} = undef;
      return $envs->{$name};
    } elsif ($dontCreate) {
      # dontCreate does not imply the database will never be created,
      # so we don't want to update $self->_envs
      return; 
    } else {
      $dbPath->mkpath;
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
    $self->_errorWithCleanup("Failed to create environment $name for $databaseDir beacuse of $LMDB_File::last_err");
    return;
  }

  my $txn = $env->BeginTxn();
  
  my $DB = $txn->OpenDB();

  # ReadMode 1 gives memory pointer for perf reasons, not safe
  $DB->ReadMode(1);

  if($LMDB_File::last_err) {
    $self->_errorWithCleanup("Failed to open database $name for $databaseDir beacuse of $LMDB_File::last_err");
    return;
  }

  # Now db is open
  my $err = $txn->commit();

  if($err) {
    $self->_errorWithCleanup("Failed to commit open db tx because: $err");
    return;
  }

  $envs->{$name} = {env => $env, dbi => $DB->dbi, db => $DB};

  #say "made database $name for " .$databaseDir;

  return $envs->{$name};
}


sub cleanUp {
  if(!%$envs) {
    return;
  }

  foreach (keys %$envs ) {
    # Check defined because database may be empty (and will be stored as undef)
    if(defined $envs->{$_} ) {
      $envs->{$_}{env}->Clean();
    }
  }

  # Break reference to the environment; should cause the object DESTROY method
  # to be called; unless some bad consumer has made references to this class
  $envs = {};
}

# For now, we'll throw the error, until program is changed to expect error/success
# status from functions
sub _errorWithCleanup {
  my ($self, $msg) = @_;

  cleanUp();
  $internalLog->ERR($msg);
  # Reset error message, not sure if this is the best way
  $LMDB_File::last_err = 0;

  # Make it easier to track errors
  say STDERR "LMDB error: $msg";

  $self->log('fatal', $msg);
}

# Get a transaction for dbRead; often we may use the database in read-only
# mode
sub _getDbReadTx {
  # my ($self, $env) = @_;
  #    $_[0], $_[1];

  if($dbReadOnly) {
    if(defined $_[1]->{readOnlyTx}) {
      $_[1]->{readOnlyTx}->renew();
    } else {
      $_[1]->{readOnlyTx} = $_[1]->BeginTxn(MDB_RDONLY);
      # probably unnecessary
      $_[1]->{readOnlyTx}->reset();
    }

    return $_[1]->{readOnlyTx};
  }
}

__PACKAGE__->meta->make_immutable;

1;