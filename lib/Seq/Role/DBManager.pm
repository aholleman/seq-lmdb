use 5.10.0;
use strict;
use warnings;

package Seq::Role::DBManager;

our $VERSION = '0.001';

# ABSTRACT: Manages Database connection
# VERSION

#TODO: Better errors; Seem to get bad perf if copy error after each db call

use Moose::Role;
with 'Seq::Role::Message';

use Data::MessagePack;
use LMDB_File qw(:all);
use MooseX::Types::Path::Tiny qw/AbsPath/;
use Sort::XS;
use Scalar::Util qw/looks_like_number/;
use DDP;
use Hash::Merge::Simple qw/ merge /;

# Most common error is "MDB_NOTFOUND" which isn't nec. bad.
$LMDB_File::die_on_err = 0;

#needed so that we can initialize DBManager once
state $databaseDir;
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

#Transaction size
#Consumers can choose to ignore it, and use arbitrarily large commit sizes
#this maybe moved to Tracks::Build, or enforce internally
#transactions carry overhead
#if a transaction fails/ process dies
#the database should remain intact, just the last
#$self->commitEvery records will be missing
#The larger the transaction size, the greater the db inflation
#Even compaction, using mdb_copy may not be enough to fix it it seems
#requiring a clean re-write using single transactions
#as noted here https://github.com/LMDB/lmdb/blob/mdb.master/libraries/liblmdb/lmdb.h
has commitEvery => (
  is => 'rw',
  init_arg => undef,
  default => 1e4,
  lazy => 1,
);

#0, 1, 2
#TODO: make singleton
has overwrite => (
  is => 'ro',
  isa => 'Int',
  default => 0,
  lazy => 1,
);

# Flag for deleting tracks instead of inserting during patch* methods
has delete => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
  lazy => 1,
);


state $dbReadOnly;
has dbReadOnly => (
  is => 'rw',
  isa => 'Bool',
  default => $dbReadOnly,
  lazy => 1,
);

sub setDbReadOnly {
  $dbReadOnly = $_[1];
}

sub _getDbi {
  my ($self, $name, $dontCreate) = @_;
  #using state to make implicit singleton for the state that we want
  #shared across all instances, without requiring exposing to public
  #at the moment we generate a new environment for each $name
  #because we can only have one writer per environment,
  #across all threads
  #and because there is some minor overhead with opening many named databases
  state $dbis;
  state $envs;

  return $dbis->{$name} if defined $dbis->{$name};
  
  my $dbPath = $self->database_dir->child($name);

  #create database unless dontCreate flag set
  if(!$dontCreate && !$self->dbReadOnly) {
    if(!$self->database_dir->child($name)->is_dir) {
      $self->database_dir->child($name)->mkpath;
    }
  }

  $dbPath = $dbPath->stringify;

  my $flags;
  if($self->dbReadOnly) {
    $flags = MDB_NOTLS | MDB_NOMETASYNC | MDB_NOLOCK | MDB_NOSYNC;
  } else {
    $flags = MDB_NOTLS | MDB_WRITEMAP | MDB_NOMETASYNC;
  }

  $envs->{$name} = $envs->{$name} ? $envs->{$name} : LMDB::Env->new($dbPath, {
      mapsize => 128 * 1024 * 1024 * 1024, # Plenty space, don't worry
      #maxdbs => 20, # Some databases
      mode   => 0600,
      #can't just use ternary that outputs 0 if not read only...
      #MDB_RDONLY can also be set per-transcation; it's just not mentioned 
      #in the docs
      flags => $flags,
      maxreaders => 1000,
      maxdbs => 1, # Some databases; else we get a MDB_DBS_FULL error (max db limit reached)
  });

  #if we passed $dontCreate, we may not successfully make a new env
  if(!$envs->{$name} ) {
    $self->log('warn', "Failed to open database because $LMDB_File::last_err");
    $LMDB_File::last_err = 0;
    return;
  }

  my $txn = $envs->{$name}->BeginTxn(); # Open a new transaction
  
  my $DB = $txn->OpenDB();

  #means we have unsafe reading; gives memory pointer for perf reasons
  $DB->ReadMode(1);

  #unfortunately if we close the transaction, cursors stop working
  #a limitation of the current API
  $txn->commit(); #now db is open

  #my $status = $envs->{$name}->stat;

  $dbis->{$name} = {
    env => $envs->{$name},
    dbi => $DB->dbi,
    path => $dbPath,
  };

  return $dbis->{$name};
}

# Our packing function
my $mp = Data::MessagePack->new();
$mp->prefer_integer(); #treat "1" as an integer, save more space

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
#was having huge performance issues. so trying to separate read and
#write transactions
# this mutates posHref
# accepts single position, or array reference of positions
# not completely safe, people could pass garbage, but we expect better
#by default sort, but, sometimes we may not want to do that by default
#To save time, I just re-assign $posAref
#However that proved annoying in practice
sub dbRead {
  #my ($self, $chr, $posAref) = @_;
  #== $_[0], $_[1], $_[2] (don't assign to avoid copy)
  my $db = $_[0]->_getDbi($_[1]);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  my @out;
  my $json;

  #will return a single value if we were passed one value
  if(!ref $_[2] ) {
    $txn->get($dbi, $_[2], $json);
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $_[0]->log('warn', "LMDB get error" . $LMDB_File::last_err);
    }
    $txn->commit();
    $LMDB_File::last_err = 0;
    return $json ? $mp->unpack($json) : undef;
  }

  #or an array of values, in order
  for my $pos ( @{ $_[2] } ) {
    $txn->get($dbi, $pos, $json);
    if(!$json) {
      if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
        $_[0]->log('warn', "LMDB get error" . $LMDB_File::last_err);
      }

      #we return exactly the # of items, and order, given to us
      #but 
      push @out, undef;
      next;
    }
    push @out, $mp->unpack($json);
  }
  $txn->commit();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  #will return a single value if we were passed one value
  return \@out;
}

# Method to write one position in the database, as a hash
#$pos can be any string, identifies a key within the kv database
#dataHref should be {someTrackName => someData} that belongs at $chr:$pos
#i.e some key in the hash found at the key in the kv database
sub dbPatchHash {
  my ( $self, $chr, $pos, $dataHref, $overrideOverwrite) = @_;

  if(ref $dataHref ne 'HASH') {
    return $self->log('fatal', "dbPatchHash requires a 1-element hash of a hash");
  }

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  my $overwrite = $overrideOverwrite || $self->overwrite;

  # Get existing data
  my $json; 
  $txn->get($dbi, $pos, $json);
  # Commit to avoid db inflation
  $txn->commit();

  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    $self->log('warn', "LMDB get error" . $LMDB_File::last_err);
  }

  # If deleting, and there is no existing data, nothing to do
  if(!$json && $self->delete) { return; }

  if($json) {
    my $href = $mp->unpack($json);

    my ($trackKey, $trackValue) = %{$dataHref};

    if( defined $href->{$trackKey} ) {
      # Deletion and insertion are mutually exclusive
      if($self->delete) {
        delete $href->{$trackKey};
      } else {
        # If not overwriting, nothing to do, return from function
        if(!$overwrite) { return; }

        # Merge with righthand hash taking precedence, https://ideone.com/SBbfYV
        if($overwrite == 1) { $href = merge $href, $dataHref; }
        if($overwrite == 2) { $href->{$trackKey} = $trackValue; }
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
  
  #Then write the new data, re-using the stack for efficiency
  goto &dbPut;
}
  
# Method to write multiple positions in the database, as arrays
sub dbPatchBulkArray {
  my ( $self, $chr, $posHref, $overrideOverwrite) = @_;

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  #https://ideone.com/Y0C4tX
  my $overwrite = $overrideOverwrite || $self->overwrite;

  for my $pos ( keys %$posHref ) {
    if(ref $posHref->{$pos} ne 'HASH') {
      return $self->log('fatal', "dbPatchBulkAsArray requires a 1-element hash of a hash");
    }

    my ($trackIndex, $trackValue) = %{ $posHref->{$pos} };
    
    my $json; #zero-copy
    $txn->get($dbi, $pos, $json);

    #trigger this only if json isn't found, save on many if calls
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $self->log('warn', "dbPatchBulk error" . $LMDB_File::last_err);
    }

    my $aref = [];

    if(defined $json) {
      #can't modify $json, read-only value, from memory map
      $aref = $mp->unpack($json);

      if(defined $aref->[$trackIndex] ) {
        # Delete by removing $trackIndex and any undefined adjacent undef values to avoid inflation
        if($self->delete) {
          splice(@$aref, $trackIndex, 1);

          # If this was also the last element in the array, it is safe to remove
          # any adjacent entries that aren't defined, since indice order will remain preserved
          if($trackIndex == @$aref) {
            SHORTEN_LOOP: for (my $i = $#$aref; $i >= 0; $i--) {
              if(! defined $aref->[$i]) {
                splice(@$aref, $i, 1);
                next SHORTEN_LOOP;
              }

              # We found a defined val, so we're done (array should remain sparse)
              last SHORTEN_LOOP;
            }
          }

          # Update the record that will be inserted to reflect the deletion
          $posHref->{$pos} = $aref;
          next; 
        }

        # If overwrite not set, skip this position since we pass posHref to dbPutBulk
        if(!$overwrite) {
          delete $posHref->{$pos};
          next;
        }

        # Overwrite
        $aref->[$trackIndex] = $trackValue;
        $posHref->{$pos} = $aref;
        next;
      }
    }

    # If the track data wasn't found in $json, don't accidentally insert it into the db
    if( $self->delete ) {
      delete $posHref->{$pos};
      next;
    }

    # Either $json not defiend ($aref empty) or trackIndex not defined
    # If array is large enough to accomodate $trackIndex, set trackValue
    # Else, grow it to the correct size, and set trackValue as the last element
    if(@$aref > $trackIndex) {
      $aref->[$trackIndex] = $trackValue;
    } else {
      # Array is shorter, down to 0 length #https://ideone.com/SdwXgu
      for (my $i = @$aref; $i < $trackIndex; $i++) {
        push @$aref, undef;
      }

      # Make the trackValue the last entry, guaranteed to be @ $aref->[$trackIndex]
      push @$aref, $trackValue;
    }
    
    $posHref->{$pos} = $aref;
  }

  $txn->commit();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  goto &dbPutBulk;
}

sub dbPut {
  my ( $self, $chr, $pos, $data) = @_;

  my $db = $self->_getDbi($chr);
  my $txn = $db->{env}->BeginTxn();

  $txn->put($db->{dbi}, $pos, $mp->pack( $data ) );

  if($LMDB_File::last_err) {
    $self->log('warn', 'dbPut error: ' . $LMDB_File::last_err);
  }

  $txn->commit();
  
  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

sub dbPutBulk {
  my ( $self, $chr, $posHref) = @_;

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn();

  #Enforce putting in ascending lexical or numerical order
  my $sortedPosAref = xsort( [keys %{$posHref} ] );

  for my $pos (@$sortedPosAref) {
    $txn->put($dbi, $pos, $mp->pack( $posHref->{$pos} ) );

    if($LMDB_File::last_err) {
      $self->log('warn', 'dbPutBulk error: ' . $LMDB_File::last_err);
    }
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
      $_[0]->log('warn', 'found non MDB_FOUND LMDB_FILE error in dbReadAll: '.
        $LMDB_FILE::last_err );
      next;
    }

    $out{$key} = $mp->unpack($value);
  }

  $txn->commit();
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
  my ( $self, $databaseName, $metaType ) = @_;
  
  #dbGet returns an array only when it's given an array
  #so for a single "position"/key (in our case $metaType)
  #only a single value should be returned (whether a hash, or something else
  # based on caller's expectations)
  #don't sort 
  return $self->dbRead($databaseName . $metaDbNamePart, $metaType, 1);
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

no Moose::Role;

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
