use 5.10.0;
use strict;
use warnings;
  # Adds cadd data to our main database
  # Reads CADD's bed-like format
package Seq::Tracks::Cadd::Build;

use Moose;
extends 'Seq::Tracks::Build';

use List::MoreUtils qw/first_index/;
use Scalar::Util qw/looks_like_number/;
use DDP;

use Seq::Tracks::Score::Build::Round;
my $rounder = Seq::Tracks::Score::Build::Round->new();

# Cadd tracks seem to be 1 based (not well documented)
has '+based' => (
  default => 1,
);
  
# TODO: Maybe enable users to specify features; for now we always report PHRED
# has '+features' => (
#   default => 'PHRED',
# );

# Works, but will take days to finish, should make a faster solution.
# TODO: split up cadd file in advance?
sub buildTrack {
  my $self = shift;

  #there can only be one, one ring to rule them all
  my ($file) = $self->allLocalFiles;

  my $fh = $self->get_read_fh($file);

  my $columnDelimiter = $self->delimiter;

  my $versionLine = <$fh>;
  chomp $versionLine;
  
  if( index($versionLine, '## CADD') == - 1) {
    $self->log('fatal', "First line of CADD file is not CADD formatted: $_");
  }

  $self->log("info", "Building ". $self->name . " version: $versionLine");

  # Cadd's real header is on the 2nd line
  my $headerLine = <$fh>;
  chomp $headerLine;

  # We may have converted the CADD file to a BED-like format, which has
  # chrom chromStart chromEnd instead of #Chrom Pos
  # Moving $phastIdx to the last column
  my @headerFields = split $columnDelimiter, $headerLine;
  # Get the last index, that's where the phast column lives https://ideone.com/zgtKuf
  # Can be 5th or 6th column. 5th for CADD file, 6th for BED-like file
  my $phastIdx = $#headerFields;

  #accumulate 3 lines worth of PHRED scores
  my @score;

  my %out;
  my $count = 0;
  my $wantedChr;

  # Track which fields we recorded, to record in $self->completionMeta
  my %visitedChrs;

  # We assume the file is sorted by chr, but will find out if not (probably)
  while (<$fh>) {
    chomp;
    my @line = split "\t", $_;

    my $chr = "chr$line[0]";

    if( !$wantedChr || ($wantedChr && $wantedChr ne $chr) ) {
      if(%out) {
        if(!$wantedChr) { $self->log('fatal', "Changed chr @ $_; out w/o wantedChr"); }
        
        $self->dbPatchBulkArray($wantedChr, \%out);
        undef %out; $count = 0;
      }

      if(@score) {
        $self->log('fatal', "Changed chr @ $_: un-saved scores: " . join(',', @score) );
        undef @score;
      }

      # Completion meta checks to see whether this track is already recorded
      # as complete for the chromosome, for this track
      if( $self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr) ) {
        $wantedChr = $chr;
      } else {
        $wantedChr = undef;
      }
    }

    if(!$wantedChr) {
      next;
    }

    # Specify 2 significant figures by default
    push @score, $rounder->round($line[$phastIdx]);
    
    if(@score < 3) {
      next;
    }

    # We have all 3 scores accumulated
    
    # CADD trcks are 1-indexed
    my $dbPosition = $line[1] - $self->based;

    # Copy array #https://ideone.com/m08q9V ; https://ideone.com/dZ6RGj
    $out{$dbPosition} = $self->prepareData([@score]);
    
    undef @score;

    if($count >= $self->commitEvery) {
      $self->dbPatchBulkArray($wantedChr, \%out);

      undef %out;
      $count = 0;
    }

    # Count 3-mer scores recorded for commitEvery, & chromosomes seen for completion recording
    if(!defined $visitedChrs{$chr} ) { $visitedChrs{$chr} = 1 };
    $count++;
  }

  # leftovers
  if(%out) {
    if(!$wantedChr) { $self->log('fatal', "Have out but no wantedChr"); }
    if(@score) { 
      $self->log('warn', "At end of $file have uncommited scores: " . join(',', @score) ); 
    }

    $self->dbPatchBulkArray($wantedChr, \%out);
  }

  # Since any detected errors are fatal, we have confidence that anything visited
  # Is complete (we only have 1 file to read)
  foreach (keys %visitedChrs) {
    $self->completionMeta->recordCompletion($_);
  }

  return 0;
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
