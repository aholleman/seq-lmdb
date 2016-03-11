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
with 'Seq::Role::Message';

use DDP;
use Sort::XS;

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

#every 1M records by default between transactions
#this isn't enforced here; individual build methods should use it
#maybe move this to Build.pm, although we could certainly do that here
#rationale for not making huge commitEvery is mostly that 
#Perl gets slow with very big hashes
#transactions carry overhead
#if a transaction fails/ process dies
#the database should remain intact, just the last
#$self->commitEvery records will be missing
has commitEvery => (
  is => 'ro',
  init_arg => undef,
  default => 1e6,
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

# sub BUILD {
#   my $self = shift;

#   say "Overwrite is" .  int($self->overwrite);
# }

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
      mapsize => 128 * 1024 * 1024 * 1024, # Plenty space, don't worry
      #maxdbs => 20, # Some databases
      mode   => 0755,
      #can't just use ternary that outputs 0 if not read only...
      #MDB_RDONLY can also be set per-transcation; it's just not mentioned 
      #in the docs
      flags => MDB_NOTLS | MDB_NOMETASYNC,
      maxreaders => 1000,
      maxdbs => 1, # Some databases; else we get a MDB_DBS_FULL error (max db limit reached)
  });

  my $txn = $envs->{$name}->BeginTxn(); # Open a new transaction
 
  my $DB = $self->_openDB($txn);

  $txn->commit(); #now db is open

  my $status = $envs->{$name}->stat;

  $dbis->{$name} = {
    env => $envs->{$name},
    dbi => $DB->dbi,
  };

  return $dbis->{$name};
}

sub _openDB {
  my ($self, $txn) = @_;

  my $DB = $txn->OpenDB();

  #by doing this, we get zero-copy db reads (we take the data from memory)
  $DB->ReadMode(1);

  return $DB;
}

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
sub dbRead {
  my ($self, $chr, $posAref) = @_;

  my $db = $self->getDbi($chr);
  my $dbi = $db->{dbi};
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  #carries less than a .2s penalty for sorting 1M records (for already in order records)
  my $sortedPos = ref $posAref eq 'ARRAY' ? xsort($posAref) : [$posAref];

  #say "sorted pos length is " . scalar @$sortedPos;
  
  my @out;
  for my $pos (@$sortedPos) {
    my $json;
    $txn->get($dbi, $pos, $json);
    if(!$json) {
      if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
        $self->tee_logger('warn', "LMDB get error" . $LMDB_File::last_err);
      }
      next;
    }
    push @out, decode_json($json);
  }
  $txn->commit();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;

  return \@out;
}

#expects one track per call ; each posHref should have {pos => {trackName => trackData} }
sub dbPatchBulk {
  my ( $self, $chr, $posHref ) = @_;

  my $db = $self->getDbi($chr);
  my $dbi = $db->{dbi};

  #I've confirmed setting MDB_RDONLY works, by trying with $txn->put;
  my $txn = $db->{env}->BeginTxn(MDB_RDONLY);

  my $cnt = 0;

  $_[3] = xsort([keys %{$posHref} ] );
  
  for my $pos (@{$_[3] }) { #want sequential
    my $json; #zero-copy
    my $href;

    $txn->get($dbi, $pos, $json);

   # say "Last error is " . $LMDB_File::last_err;
    if($json) {
      my ($featureID) = %{$posHref->{$pos} };
      #can't modify $json, read-only value, from memory map
      $href = decode_json($json);

      # say "previous href was";
      # p $previous_href;
      if(!$self->overwrite) {
        if(defined $href->{$featureID} ) {
          #since we already have this feature, no need to write it
          #since we don't want to overwrite
          #requires us to check if $posHref->{$pos} is defined in 
          delete $posHref->{$pos};

          next;
        }
      } # else we want to overwrite
      $href->{$featureID} = $posHref->{$pos}{$featureID};
      $posHref->{$pos} = $href;
      
      #deep merge is much more robust, but I'm worried about performance, so trying alternative
      #$previous_href = merge $previous_href, $posHref->{$pos}; #righthand merge
      next;
    }
    #trigger this only if json isn't found, save on many if calls
    #unless is apparently a bit faster than if, when looking for negative conditions
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $self->tee_logger('warn', "LMDB get error" . $LMDB_File::last_err);
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

sub dbPutBulk {
  my ( $self, $chr, $posHref, $sortedPosAref) = @_;

  my $db = $self->getDbi($chr);
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

    $txn->put($dbi, $pos, encode_json($posHref->{$pos} ) );

    #should move logging to async
    #have the MDB_NOTFOUND thing becaues this could follow a get operation
    #which could generate and MDB_NOTFOUND
    #to short circuit, speed the if, set $LMDB_FILE::last_err to 0 after
    #a bulk get
    #unless is apparently a bit faster than if, when looking for negative conditions
    if($LMDB_File::last_err && $LMDB_File::last_err != MDB_NOTFOUND) {
      $self->tee_logger('warn', 'LMDB PUT ERROR: ' . $LMDB_File::last_err);
    }
  }

  $txn->commit();

  #reset the class error variable, to avoid crazy error reporting later
  $LMDB_File::last_err = 0;
}

no Moose::Role;

1;


# backup

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

# sub dbPatchBulk {
#   my ( $self, $chr, $posHref ) = @_;

#   my $db = $self->getDbi($chr);
#   my $dbi = $db->{dbi};
#   my $txn = $db->{env}->BeginTxn();

#   my $cnt = 0;
#   for my $pos (sort { $a <=> $b } keys %{$posHref} ) { #want sequential
#     my $json; #zero-copy
#     my $href;
#     my $response;
#     # say "pos is $pos";
#     # my $response = $txn->get($dbi, $pos, $json);
#     # if($response) {
#     #   if($response == MDB_NOTFOUND) {
#     #     #nothing found
#     #   }
#     # } else {
#     #   $self->tee_logger('warn', "DBI error: $response");
#     # }

#    # say "Last error is " . $LMDB_File::last_err;
#     if($json) {
#       my ($featureID) = %{$posHref->{$pos} };
#       #can't modify $json, read-only value, from memory map
#       $href = decode_json($json);

#       # say "previous href was";
#       # p $previous_href;
#       if(!$self->overwrite) {
#         if(defined $href->{$featureID} ) {
#           #say "defined $featureID, skipping";
#           next;
#         }
#       }
#       $href->{$featureID} = $posHref->{$pos}{$featureID};
#       #much more robust, but I'm worried about performance, so trying alternative
#       #$previous_href = merge $previous_href, $posHref->{$pos}; #righthand merge
#     } else {
#       $href = $posHref->{$pos};
#     }
#     #say "about to put in $chr $pos";
#     #p $href;
#     $response = $txn->put($dbi, $pos, encode_json($href) );
#     #say "response was";
#     #p $response;
#     $cnt++;
#     if($cnt > $self->commitEvery) {
#       $cnt = 0;
#       $txn->commit();
#       $txn = $db->{env}->BeginTxn();
#     }
#   }

#   $txn->commit();
# }

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