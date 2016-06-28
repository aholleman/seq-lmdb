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

#TODO: like with sparse tracks, allow users to map required fields
use MCE::Loop;

use Seq::Tracks::Score::Build::Round;
my $rounder = Seq::Tracks::Score::Build::Round->new();

# sparse track should be 1 based by default 
has '+based' => (
  default => 1,
);
  
#if use doesn't specify a feature, give them the PHRED score
# TODO: Maybe enable this; for now we just report a single score, PHRED
# and this is identified just like other score tracks, by the track name
# has '+features' => (
#   default => 'PHRED',
# );

sub buildTrack {
  my ($self) = @_;

  my ($file) = $self->allLocalFiles;

  my $fh = $self->get_read_fh($file);

  if( index($fh->getline(), '## CADD') > - 1) {
    close $fh;
    goto &buildTrackFromCaddOrBedFormat;
  }

  goto &buildTrackFromHeaderlessWigFix;
}

# Works, but will take days to finish, should make a faster solution.
# TODO: split up cadd file in advance?
sub buildTrackFromCaddOrBedFormat {
  my $self = shift;

  #there can only be one, one ring to rule them all
  my ($file) = $self->allLocalFiles;

  #DOESN'T WORK WITH MCE for compressed files!
  my $fh = $self->get_read_fh($file);

  my $columnDelimiter = $self->delimiter;

  my $versionLine = <$fh>;
  chomp $versionLine;
  
  $self->log("info", "Building ". $self->name . " version: $versionLine");

  # Cadd's real header is on the 2nd line
  my $headerLine = <$fh>;
  chomp $headerLine;

  # We may have converted the CADD file to a BED-like format, which has
  # chrom chromStart chromEnd instead of #Chrom Pos
  # Moving $phastIdx to the last column
  my @headerFields = split $columnDelimiter, $headerLine;
  # Get the last index, that's where the phast column lives https://ideone.com/zgtKuf
  my $phastIdx = $#headerFields;

  #accumulate 3 lines worth of PHRED scores
  my @score;

  my %out;
  my $count = 0;
  my $wantedChr;

  my $numericalChr = $self->wantedChr ? substr($self->wantedChr, 3) : undef;
  if(!looks_like_number($numericalChr) ) { $numericalChr = undef; }
  my $nChrLength = length($numericalChr);
  
  # We assume the file is sorted by chr
  while (<$fh>) {
    my $chr = substr($_, 0, $nChrLength ? $nChrLength : index($_, "\t") );

    # If we only want 1 chromosome, save time by avoiding split 
    # any remaining %out will still be written by the last %out check
    if( $numericalChr && looks_like_number($chr) && $chr > $numericalChr ) { last; } 

    $chr = "chr$chr";

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

      $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
    }

    if(!$wantedChr) {
      next;
    }

    chomp;

    my @line = split "\t", $_;

    #specify 2 significant figures
    #store as strings because Data::MessagePack seems to store all floats in 9 bytes
    push @score, $rounder->round($line[$phastIdx]);
    
    if(@score < 3) {
      next;
    }

    #We have all 3 scores accumulated
    
    #CADD trcks are 1-indexed
    my $dbPosition = $line[1] - $self->based;

    # copy array #https://ideone.com/m08q9V
    # https://ideone.com/dZ6RGj
    $out{$dbPosition} = $self->prepareData([@score]);
    
    undef @score;

    if($count >= $self->commitEvery) {
      $self->dbPatchBulkArray($wantedChr, \%out);

      undef %out;
      $count = 0;
    }

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
