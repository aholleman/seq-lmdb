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
  my ($self) = @_;

  my ($file) = $self->allLocalFiles;

  my $fh = $self->get_read_fh($file);
  
  if( index($fh->getline(), '## CADD') > - 1) {
    close $fh;
    goto &buildTrackFromCaddFormat;
  }

  goto &buildTrackFromHeaderlessWigFix;
}

sub buildTrackFromCaddFormat {
  my $self = shift;

  #there can only be one, one ring to rule them all
  my ($file) = $self->allLocalFiles;

  #DOESN'T WORK WITH MCE for compressed files!
  my $fh = $self->get_read_fh($file);

  my $columnDelimiter = $self->delimiter;

  my $versionLine = <$fh>;
  chomp $versionLine;
  
  $self->log("info", "Building ". $self->name . " version: $versionLine");

  #skip one more line, want to %3 chunk input lines
  my $headerLine = <$fh>;

  MCE::Loop::init(
    #3 chunk, because each position should have 3 values
    chunk_size => 3,
    max_workers => 30,
    use_slurpio => 1,
    on_post_run => sub {
      my ($mce, $allWorkers) = @_;

      #Report only one exit code
      for my $worker (@$allWorkers) {
        if ($worker->{status} != 0) {
          $self->log('warn', $self->name . " worker exited with $worker->{status}");
          return;
        }
      }
    },
  );

  mce_loop_f {
    my ($mce, $slurpRef, $chunkID) = @_;

    my @lines;

    open my $MEM_FH, '<', $slurpRef;
    binmode $MEM_FH, ':raw';
    while (<$MEM_FH>) { if($_ !~ /^\s*$/ ) { chomp $_; push @lines, $_; } }
    close   $MEM_FH;

    if(@lines == 3) {
      my @score;
      my @splitLines = map { [split $columnDelimiter, $_] } @lines;

      #check that the lines are sync'd as we expect
      my $chr = $splitLines[0]->[0];
      my $position = $splitLines[0]->[1];

      my $namedChr = "chr$chr";

      if(!$self->chrIsWanted($namedChr) ) {
        next;
      }

      my $dbPosition = $position - $self->based;

      for my $lineAref (@splitLines) {
        #cadd stores chromosomes numerically
        if($chr != $lineAref->[0]) {
          $self->log('warn', "consecutive lines had different chr", join(",", @lines) );
          next;
        }

        if( $position != $lineAref->[1] ) {
          $self->log('warn', "consecutive lines had different positions", join(",", @lines) );
          next;
        }

        #PHRED
        push @score, $lineAref->[5];
      }

      if( @score == 3) {
        $self->dbPatchBulk($namedChr, {
          $dbPosition => $self->prepareData(\@score)
        });
      } else {
        $self->log('warn', "Couldn't accumulate all 3 values for $chr:$position");
      }
    } else {
      $self->log('warn', "Couldn't accumulate all 3 values for ". join(",", @lines) );
    }

    undef @lines;
  } $fh;
}

sub buildTrackFromHeaderlessWigFix {
  my $self = shift;
say "building in wigfix format";
  #there can only be ONE
  #the one that binds them
  my @files = $self->allLocalFiles;

  my ($file) = @files;

  if(@files > 1) {
    $self->log('warn', 'In Cadd/Buil more than one local_file specified. Taking first,
      which is ' . $file);
  }

  my $fh = $self->get_read_fh($file);
  
  my $wantedChr;
  
  my $count = 0;

  # sparse track should be 1 based
  # we have a method ->zeroBased, but in practice I find it more confusing to use
  my $based = $self->based;

  my $delimiter = $self->delimiter;

  MCE::Loop::init {
    chunk_size => 2e8, #read in chunks of 200MB
    max_workers => 30,
    use_slurpio => 1,
    gather => \&writeToDatabase,
  };

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    my @lines;

    open my $MEM_FH, '<', $slurp_ref;
    binmode $MEM_FH, ':raw';
    while (<$MEM_FH>) { push @lines, $_; }
    close   $MEM_FH;

    # storing
    # chr => {
      #pos => {
    #    $self->dbName => [val1, val2, val3]
    #  }
    #}
    my %out;

    #count number of positions recorded for each chr  so that 
    #we can comply with $self->commitEvery
    my %count;

    LINE_LOOP: for my $line (@lines) {
      #wantedChr means user has asked for just one chromosome
      if($self->wantedChr && index($line, $self->wantedChr) == -1) {
        next LINE_LOOP;
      }

      chomp $line;

      my @sLine = split $delimiter, $line;

      my $chr = $sLine[0];

      my $dbPosition = $sLine[1] - $based;
      #if no single --chr is specified at run time,
      #check against list of genome_chrs
      if(!$self->chrIsWanted( $chr ) ) {
        next;
      }

      if(! defined $out{ $chr } ) {
        undef $out{ $chr };
        $count{ $sLine[0] } = 0;
      }

      #if this chr has more than $self->commitEvery records, put it in db
      if( $count{ $chr } == $self->commitEvery ) {
        MCE->gather($self, { $chr => $out{ $chr } } );
        
        undef $out{ $chr };
        $count{ $chr } = 0;
      }

      $out{ $chr }{ $dbPosition } = $self->prepareData( [$sLine[2], $sLine[3], $sLine[4]] );
      $count{ $chr }++;
    }

    # http://www.perlmonks.org/?node_id=1110235
    if(%out) {
      MCE->gather($self, \%out);
    }

    undef %out;
    undef %count;
  } $fh;

  $self->log('info', 'finished building: ' . $self->name);
}

sub writeToDatabase {
  my ($self, $resultRef) = @_;

  for my $chr (keys %$resultRef) {
    if( %{ $resultRef->{$chr} } ) {
      $self->dbPatchBulk($chr, $resultRef->{$chr} );
    }
  }

  undef $resultRef;
}

__PACKAGE__->meta->make_immutable;
1;
