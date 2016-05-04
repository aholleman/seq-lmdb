#TODO: needs to return errors if they're really errors and not
#"something was missing" during patch operations for instance
#but that may be difficult with the currrent LMDB_File API
#I've had very bad performance returning errors from transactions
#which are exposed in the C api
#but I may have mistook one issue for another
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
with 'Seq::Role::Message';

use Data::MessagePack;
use LMDB_File qw(:all);
use MooseX::Types::Path::Tiny qw/AbsPath/;
use Sort::XS;
use Scalar::Util qw/looks_like_number/;
use DDP;

#weird error handling in LMDB_FILE for the low level api
#the most common errors mean nothign bad (ex: not found for get operations)
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

#to store any records
#For instance, here we can store our feature name mappings, our type mappings
#whether or not a particular track has completed writing, etc
state $metaDbNamePart = '_meta';

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

has overwrite => (
  is => 'ro',
  isa => 'Bool',
  default => 0,
  lazy => 1,
);

sub _getDbi {
  my ($self, $name) = @_;
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
  if(!$self->database_dir->child($name)->is_dir) {
    $self->database_dir->child($name)->mkpath;
  }

  $dbPath = $dbPath->stringify;

  $envs->{$name} = $envs->{$name} ? $envs->{$name} : LMDB::Env->new($dbPath, {
      mapsize => 128 * 1024 * 1024 * 1024, # Plenty space, don't worry
      #maxdbs => 20, # Some databases
      mode   => 0600,
      #can't just use ternary that outputs 0 if not read only...
      #MDB_RDONLY can also be set per-transcation; it's just not mentioned 
      #in the docs
      flags => MDB_NOTLS | MDB_WRITEMAP | MDB_NOMETASYNC
      maxreaders => 1000,
      maxdbs => 1, # Some databases; else we get a MDB_DBS_FULL error (max db limit reached)
  });

  my $txn = $envs->{$name}->BeginTxn(); # Open a new transaction
  
  my $DB = $txn->OpenDB();
  $DB->ReadMode(1);

  #unfortunately if we close the transaction, cursors stop working
  #a limitation of the current API
  $txn->commit(); #now db is open

  #my $status = $envs->{$name}->stat;

  $dbis->{$name} = {
    env => $envs->{$name},
    dbi => $DB->dbi,
  };

  return $dbis->{$name};
}

# I think this is too simple to warrant a function,
# also only used in 2 places, above and in readAll (readAll open may go away)
# sub _openDB {
#  # my ($self, $txn) = @_;
#  # 
#   my $DB = $txn->OpenDB();

#   #by doing this, we get zero-copy db reads (we take the data from memory)
#   $DB->ReadMode(1);

#   return $DB;
# }

#We could use the static method; not sure which is faster
#But goal is to make sure we treat strings that look like integers as integers
#Avoid weird dynamic typing issues that impact space
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
  #modify $oAref in place, to save one array assignment;
  for my $pos (ref  $_[2] ? @{ $_[2] } : [ $_[2] ] ) {
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
  return @out == 1 ? $out[0] : \@out;
}

#$pos can be any string, identifies a key within the kv database
#dataHref should be {someTrackName => someData} that belongs at $chr:$pos
#i.e some key in the hash found at the key in the kv database
sub dbPatch {
  my ( $self, $chr, $pos, $dataHref, $noOverwrite) = @_;

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  
  #I've confirmed setting MDB_RDONLY works, by trying with $txn->put;
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  my $cnt = 0;

  my $json; #zero-copy
  my $href;

  #First get the old data,
  $txn->get($dbi, $pos, $json);
  #commit, because we don't want db inflation during the write stage
  $txn->commit();

  #trigger this only if json isn't found, save on many if calls
  #unless is apparently a bit faster than if, when looking for negative conditions
  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    $self->log('warn', "LMDB get error" . $LMDB_File::last_err);
  }
    
  #If we have data, unpack it to get the hash ref treats
  #And then replace the old data with $dataHref
  if($json) {
    #takes the key name of the data href
    #expects only one, since this is not a bulk method
    #can't modify $json, read-only value, from memory map
    $href = $mp->unpack($json);

    my ($featureID) = %{$dataHref};

    # don't overwrite if the user doesn't want it
    # just mark to skip
    if( defined $href->{$featureID} ) {
      if(defined $noOverwrite) {
        if($noOverwrite) {
          return;
        }
      } elsif(!$self->overwrite) {
        return;
      }
    }
    
    # else we want to overwrite
    $href->{$featureID} = $dataHref->{$featureID};
    #update the stack copy of data to include everything found at the pos (key)
    #_[3] == $dataHref, but the actual reference to it
    $_[3] = $href;
  }
  
  #reset the calls error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
  
  #Then write the new data
  #re-use the stack for efficiency
  goto &dbPut;
}

#expects one track per call ; each posHref should have {pos => {trackName => trackData} }
sub dbPatchBulk {
  my ( $self, $chr, $posHref, $noOverwrite) = @_;

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  
  #I've confirmed setting MDB_RDONLY works, by trying with $txn->put;
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  my $cnt = 0;

  #https://ideone.com/Y0C4tX
  my $tOverWrite = $noOverwrite ? 0 : ($self->overwrite ? 1 : 0);

  #modifies the stack, but hopefully a smaller change than a full
  #new stack + function call (look to goto below)
  $_[3] = xsort([keys %{$posHref} ] );
  
  for my $pos (@{$_[3] }) { #want sequential
    my $json; #zero-copy
    my $href;

    $txn->get($dbi, $pos, $json);

    if($json) {
      my ($featureID) = %{$posHref->{$pos} };
      #can't modify $json, read-only value, from memory map
      $href = $mp->unpack($json);

      if(!$tOverWrite) {
        if(defined $href->{$featureID} ) {
          #since we already have this feature, no need to write it
          #since we don't want to overwrite
          #requires us to check if $posHref->{$pos} is defined in 
          delete $posHref->{$pos};

          next;
        }
      } # else we want to overwrite
      $href->{$featureID} = $posHref->{$pos}{$featureID};
      #update the stack data to include everything found at the key
      #this allows us to reuse the stack in a goto,
      $posHref->{$pos} = $href;
      
      #deep merge is much more robust, but I'm worried about performance, so trying alternative
      #$previous_href = merge $previous_href, $posHref->{$pos}; #righthand merge
      next;
    }
    #trigger this only if json isn't found, save on many if calls
    #unless is apparently a bit faster than if, when looking for negative conditions
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $self->log('warn', "LMDB get error" . $LMDB_File::last_err);
    }
    #if nothing exists; then we still want to pass it on to
    #the writer, even if !overwrite is true

    #Undecided whether DBManager should throttle writes; in principle yes
    #but hashes passed to DBManager get ridiculously large,
    #unless Seq::Tracks::Build throttles them (and declares commitEvery)
  }

  $txn->commit();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  #re-use the stack for efficiency
  goto &dbPutBulk;
}

sub dbPut {
  my ( $self, $chr, $pos, $dataHref) = @_;

  my $db = $self->_getDbi($chr);
  my $txn = $db->{env}->BeginTxn();

  $txn->put($db->{dbi}, $pos, $mp->pack( $dataHref ) );

  #should move logging to async
  #have the MDB_NOTFOUND thing becaues this could follow a get operation
  #which could generate and MDB_NOTFOUND
  #to short circuit, speed the if, set $LMDB_FILE::last_err to 0 after
  #a bulk get
  #unless is apparently a bit faster than if, when looking for negative conditions
  if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
    $self->log('warn', 'LMDB PUT ERROR: ' . $LMDB_File::last_err);
  }

  $txn->commit();
  
  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

sub dbPutBulk {
  my ( $self, $chr, $posHref, $sortedPosAref) = @_;

  my $db = $self->_getDbi($chr);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn();

  if(!$sortedPosAref) {
    $sortedPosAref = xsort([keys %{$posHref} ] );
  }

  my $cnt = 0;
  for my $pos (@$sortedPosAref) { #want sequential
    #by checking for defined, we can avoid having to re-sort
    #which may be slow than N if statements
    #and unless is faster than if(!)
    #(since in dbPatchBulk we may delete positions if !overwrite)
    unless(exists $posHref->{$pos} ) {
      next;
    }

    $txn->put($dbi, $pos, $mp->pack( $posHref->{$pos} ) );

    #should move logging to async
    #have the MDB_NOTFOUND thing becaues this could follow a get operation
    #which could generate and MDB_NOTFOUND
    #to short circuit, speed the if, set $LMDB_FILE::last_err to 0 after
    #a bulk get
    #unless is apparently a bit faster than if, when looking for negative conditions
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $self->log('warn', 'LMDB PUT ERROR: ' . $LMDB_File::last_err);
    }
  }

  $txn->commit();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

#TODO: Finish; should go over every record in the requested database
#and write single commit size 
#we don't care terribly much about performance here, this happens once in a great while,
#so we use our public function dbPutBulk
sub dbWriteCleanCopy {
  #for every... $self->dbPutBulk
  #dbRead N records, divide dbGetLength by some reasonable size, like 1M
}

#TODO: check if this works
sub dbGetNumberOfEntries {
  my ( $self, $chr ) = @_;

  return $self->_getDbi($chr)->{env}->stat->{entries};
}

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
#@param <String> $metaType : this is our "position" in the meta database
 # a.k.a the top-level key in that meta database, what type of meta data this is 
#@param <HashRef> $dataHref : {someField => someValue}
sub dbPatchMeta {
  my ( $self, $databaseName, $metaType, $dataHref ) = @_;
  
  # 0 in last position to always overwrite, regardless of self->overwrite
  $self->dbPatch($databaseName . $metaDbNamePart, $metaType, $dataHref, 0);
  return;
}

no Moose::Role;

1;
