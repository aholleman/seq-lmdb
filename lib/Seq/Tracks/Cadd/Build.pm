use 5.10.0;
use strict;
use warnings;
  # Adds cadd data to our main database
  # Reads CADD's bed-like format
package Seq::Tracks::Cadd::Build;

use Mouse 2;
extends 'Seq::Tracks::Build';
# use MCE_LOOP;

# use Seq::Tracks::Cadd::Order;
# use Seq::Tracks::Score::Build::Round;
# use Seq::Tracks;

my $rounder = Seq::Tracks::Score::Build::Round->new();

my $order = Seq::Tracks::Cadd::Order->new();
$order = $order->order;

# Cadd tracks seem to be 1 based (not well documented)
has '+based' => (
  default => 1,
);

my $refTrack;
sub BUILD {
  my $self = shift;

  my $tracks = Seq::Tracks->new();
  $refTrack = $tracks->getRefTrackGetter();
}

sub buildTrack {
  my $self = shift;

  my $columnDelimiter = $self->delimiter;

  # CADD lifted over files are not guaranteed to have 1 wanted chr per file
  # And since LMDB allows only one writer at a time, 
  MCE_LOOP::init { max_workers => scalar @{$self->local_files}, chunk_size => 1,
    gather => $self->makeCaddWriter() };

  mce_loop {
    my $file = shift;
    say "file name is $file";

    my $fh = $self->get_read_fh($file);

    my $versionLine = <$fh>;
    chomp $versionLine;
    
    if( index($versionLine, '## CADD') == -1) {
      $self->log('fatal', "First line of CADD file is not CADD formatted: $_");
    }

    $self->log("info", "Building ". $self->name . " version: $versionLine using $file");

    # Cadd's columns descriptor is on the 2nd line
    my $headerLine = <$fh>;
    chomp $headerLine;

    # We may have converted the CADD file to a BED-like format, which has
    # chrom chromStart chromEnd instead of #Chrom Pos
    # and which is 0-based instead of 1 based
    # Moving $phastIdx to the last column
    my @headerFields = split $columnDelimiter, $headerLine;

    # Get the last index, that's where the phast column lives https://ideone.com/zgtKuf
    # Can be 5th or 6th column idx. 5th for CADD file, 6th for BED-like file
    my $phastIdx = $#headerFields;

    my $altAlleleIdx = $#headerFields - 2;
    my $refBaseIdx = $#headerFields - 3;

    my $based = $self->based;
    my $isBed;
    
    if(@headerFields == 7) {
      # It's the bed-like format
      $based = 0;
      $isBed = 1;
    }

    # Accumulate 3 lines worth of PHRED scores
    # We cannot assume the CADD file will be properly sorted when liftOver used
    # So checks need to be made
    my %scores;

    my %out;
    my $count = 0;
    my $wantedChr;

    # Track which fields we recorded, to record in $self->completionMeta
    my %visitedChrs;

    # We assume the file is sorted by chr, but will find out if not (probably)
    FH_LOOP: while ( my $line = $fh->getline() ) {
      chomp $line;
      
      my @fields = split $columnDelimiter, $line;

      my $chr = $isBed ? $fields[0] : "chr$fields[0]";

      say "chr is $chr";

      if( !$wantedChr || ($wantedChr && $wantedChr ne $chr) ) {
        if(%out) {
          if(!$wantedChr) { $self->log('fatal', "Changed chr @ line $., but no wantedChr");}
          
          $self->db->dbPatchBulkArray($wantedChr, \%out);
          undef %out; $count = 0;
        }

        if( %scores ) {
          return $self->log('fatal', "Changed chr @ line # $. with un-saved scores");
        }

        if($wantedChr && $self->chrPerFile) {
          $self->log('warn', "Expected 1 chr per file: had $wantedChr and also found $chr");
        }

        # Completion meta checks to see whether this track is already recorded
        # as complete for the chromosome, for this track
        if( $self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr) ) {
          $wantedChr = $chr;
        } else {
          $wantedChr = undef;
        }
      }

      # We expect either one chr per file, or all in one file
      if(!$wantedChr) {
        if($self->chrPerFile) {
          last FH_LOOP;
        }
        next FH_LOOP;
      }

      my $dbPosition = $fields[1] - $based;

      my $altAllele = $fields[$altAlleleIdx];
      my $refBase = $fields[$refBaseIdx];

      say "altAllele is $altAllele and refBase is $refBase";

      # Specify 2 significant figures by default
      if(defined $scores{ref}) {
        if($scores{ref} ne $refBase) {
          return $self->log('fatal', "Multiple reference bases in 3-mer @ line # $. : $line");
        }
      } else {
        $scores{ref} = $refBase;
      }

      if(defined $scores{pos}) {
        if($scores{$pos} != $position) {
          return $self->log('fatal', "3mer out of order @ line # $. : $line");
        }
      } else {
        $scores{pos} = $dbPosition;
      }

      push ( @{ $scores{scores} }, [$altAllele, $rounder->round($fields[$phastIdx])];

      # We expect 1 position to have 3 adjacent scores
      if(@{ $scores{scores} } < 3) {
        next;
      }

      my @phastScores;
      my %uniqueScores;
      $#phastScores = 3;

      for my $aref (@{ $scores{scores} }) {
        if($refBasesFound && $aref->[0] ne $refBasesFound) {
          return $self->log('fatal', "Multiple reference bases in 3-mer");
        }

        my $index = $order->{ $scores{ref} }{ $aref->[0] };

        if(!defined $index) {
          $self->log('fatal', "ref $aref->[0] or allele $aref->[1] not ACTG");
        }

        $phastScores[$index] = $aref->[2];
        $uniqueScores{$index} = 1;
      }

      if(keys %uniqueScores < 3) {
        $self->log('fatal', "Found less than 3 unique alleles in CADD 3-mer");
      }

      my $dbData = $self->db->dbRead($dbPosition);
      my $assemblyRefBase = $refTrack->get($dbData);

      say "$assemblyRefBase is $assemblyRefBase and refBasesFound is $refBasesFound";

      if( $assemblyRefBase ne $scores{ref} ) {
        $self->log('warn', "$dbPosition refBase is $scores{ref}, whereas assembly has $assemblyRefBase");
      } else {
        # Copy array #https://ideone.com/m08q9V ; https://ideone.com/dZ6RGj
        $out{$dbPosition} = $self->prepareData( [ $scoreHash{$wantedChr}{$dbPosition} ] );
        $count++;
      }

      undef %scores;
      undef %uniqueScores;

      if($count >= $self->commitEvery) {
        $self->db->dbPatchBulkArray($wantedChr, \%out);

        undef %out;
        $count = 0;
      }

      # Count 3-mer scores recorded for commitEvery, & chromosomes seen for completion recording
      if(!defined $visitedChrs{$chr} ) { $visitedChrs{$chr} = 1 };
    }

    # leftovers
    if(%out) {
      if(!$wantedChr) { $self->log('fatal', "Have out but no wantedChr"); }
      if( %scores ) { 
        $self->log('warn', "At end of $file have uncommited scores for position $scores{pos}");
      }

      $self->db->dbPatchBulkArray($wantedChr, \%out);
    }

    $pm->finish(0, \%visitedChrs);
  }

  my %visitedChrs;
  $pm->run_on_finish(sub {
    my ($pid, $exitStatus, $fileName, $exitSignal, $coreDump, $visitedChrsHref) = @_;
    
    say "visitedChrs are";
    p $visitedChrs;

    if($exitStatus != 0) {
      $self->log('fatal', "Failed to finish with $exitStatus");
    }

    foreach (keys %$visitedChrsHref) {
      $visitedChrs{$_} = 1;
    }
  });

  $pm->wait_all_children;

  # Since any detected errors are fatal, we have confidence that anything visited
  # Is complete (we only have 1 file to read)
  foreach (keys %visitedChrs) {
    $self->completionMeta->recordCompletion($_);
  }
}

sub makeCaddWriter {
  my ($self, $visitedChrsHref) = @_;

  return sub {
    my ($chr, $outHref) = @_;

    my $err = $self->db->dbPatchBulkArray($chr, $outHref);

    if(!$err) {
      $visitedChrsHref{$chr};
    }
  }
}

sub buildTrackFromHeaderlessWigFix {
  my $self = shift;
  $self->log('fatal', "Custom wigFix format no longer allowed."
    . " Please use either CADD format, or bed-like cadd format, which should have"
    . " 2 header lines, like in a regular CADD file, with the first being"
    . " the version / copyright, the 2nd being the tab-delimited names of columns."
    . " However, on this 2nd line, instead of #Chrom\tPos the bed-like format expects"
    . " chrom chromStart chromEnd as the first 3 column names (adding chromEnd)"
    , " and regular CADD field names after that.");
}

__PACKAGE__->meta->make_immutable;
1;
