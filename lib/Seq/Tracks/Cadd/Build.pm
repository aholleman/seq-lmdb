use 5.10.0;
use strict;
use warnings;
  # Adds cadd data to our main database
  # Reads CADD's bed-like format
package Seq::Tracks::Cadd::Build;

use Moose;
extends 'Seq::Tracks::Build';
with 'Seq::Role::DBManager';

use List::MoreUtils qw/first_index/;
use DDP;

#TODO: like with sparse tracks, allow users to map required fields
use MCE::Loop;

# sparse track should be 1 based by default 
has '+based' => (
  default => 1,
);
  
#if use doesn't specify a feature, give them the PHRED score
has '+features' => (
  default => 'PHRED',
);

sub buildTrack {
  my $self = shift;

  #there can only be one, one ring to rule them all
  my ($file) = $self->allLocalFiles;

  #DOESN'T WORK WITH MCE for compressed files! Maybe not
  my $fh = $self->get_read_fh($file);

  # open( my $fh, "-|", "zcat", $file );

  my $columnDelimiter = $self->delimiter;

  my $exitStatus;

  MCE::Loop::init (
    #small chunk size to allow us to write in parallel without 
    #inflating db much
    #we read in groups of 3, to 
    chunk_size => 90,
    max_workers => 32,
    #we could use a single writer
    # gather => \&writeToDatabase,
    use_slurpio => 1,
    on_post_run => sub {
      my ($mce, $allWorkers) = @_;

      #Report only one exit code
      for my $worker (@$allWorkers) {
        if ($worker->{status} != 0) {
          $self->log('warn', $self->name . " worker exited with $worker->{status}");
          $exitStatus = $worker->{status};
          return;
        }
      }

      $exitStatus = 0;
    },

  );

  my $versionLine = <$fh>;
  chomp $versionLine;
  
  $self->log("info", "Building ". $self->name . " version: $versionLine");
  
  my $headerLine = <$fh>;
  chomp $headerLine;

  my @headerFields = split $columnDelimiter, $headerLine;

  #whatever features the user asked for
  my %featureIdx;

  #used to check whether we're getting sets of 3
  my $aFieldDbName;

  #cache our feature names
  my @featureNames = $self->allFeatureNames;

  for my $featureName (@featureNames) {
    my $fieldIdx = first_index { $_ eq $featureName } @headerFields;
    
    if($fieldIdx == -1) {
      $self->log('fatal', "required field $featureName not present");
    }

    $featureIdx{$featureName} = $fieldIdx;

    $aFieldDbName = $self->getFieldDbName($featureName);
  }

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    my @lines;

    open my $MEM_FH, '<', $slurp_ref;
    binmode $MEM_FH, ':raw';
    while (<$MEM_FH>) { push @lines, $_; }
    close   $MEM_FH;

    my %out;
    my $count = 0;

    my $wantedChr;
    LINE_LOOP: for my $line (@lines) {
      chomp $line;
      my @fields = split $columnDelimiter, $line;

      my $chr = "chr$fields[0]";

      # Remove the offset to get the real position
      my $dbPosition = $fields[1] - $self->based;

      if($wantedChr) {
        if($wantedChr ne $chr) {
          if(%out) {
            # We ASSUME that the cadd file is sorted by chr
            # We should NEVER have a case that we get here, and are missing
            # one of the 3 values
            # check this first
            foreach (keys %out) {
              if(@{ $out{$_}->{$self->dbName}{$aFieldDbName} } != 3) {
                $self->log('fatal', "CADD file mis-sorted; output for $wantedChr:$_ is "
                  . join(",", @{ $out{$_}{$aFieldDbName} } ) );
              }
            }

            $self->dbPatchBulk($wantedChr, %out);

            undef %out;
            $count = 0;
          }

          $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
        }
      } else {
        $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
      }

      if(!$wantedChr) {
        next LINE_LOOP;
      }

      #if this chr has more than $self->commitEvery records, put it in db
      if( $count >= $self->commitEvery ) {
        $self->dbPatchBulk( $wantedChr, \%out );

        undef %out;
        $count = 0;
      }

      for my $featureName (@featureNames) {
        push @{ $out{$dbPosition}{$self->dbName}{ $self->getFieldDbName($featureName) } }, 
          $fields[ $featureIdx{$featureName} ];
      }

      $count++;
    }

    # http://www.perlmonks.org/?node_id=1110235
    if(%out) {
      if(!$wantedChr) {
        $self->log('fatal', "out data remaining, but no wantedChr in " . $self->name);
      }

      # We should NEVER have a case that we get here, and are missing
      # one of the 3 values, check this first
      foreach (keys %out) {
        if(@{ $out{$_}{$self->dbName}{$aFieldDbName} } != 3) {
          $self->log('fatal', "CADD file mis-sorted; output for $wantedChr:$_ is "
            . join(",", @{ $out{$_}{$self->dbName}{$aFieldDbName} } ) );
        }
      }

      $self->dbPatchBulk($wantedChr, \%out);
    }
  } $fh;

  MCE::Loop::finish;
  return $exitStatus; 
}

# Could also do synchronous writes
# sub writeToDatabase {
#   my ($self, $resultRef) = @_;

#   for my $chr (keys %$resultRef) {
#     if( %{ $resultRef->{$chr} } ) {
#       $self->dbPatchBulk($chr, $resultRef->{$chr} );
#     }
#   }

#   undef $resultRef;
# }

__PACKAGE__->meta->make_immutable;
1;
