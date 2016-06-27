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
    goto &buildTrackFromCaddFormat;
  }

  goto &buildTrackFromHeaderlessWigFix;
}

# Works, but will take days to finish, should make a faster solution.
# TODO: split up cadd file in advance?
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
    push @score, $rounder->round($line[5]);
    
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

# sub buildTrackFromHeaderlessWigFix {
#   my $self = shift;

#   #there can only be ONE
#   #the one that binds them
#   my @files = $self->allLocalFiles;

#   my ($file) = @files;

#   if(@files > 1) {
#     $self->log('warn', 'In Cadd/Buil more than one local_file specified. Taking first,
#       which is ' . $file);
#   }

#   my $fh = $self->get_read_fh($file);
  
#   my $wantedChr;
  
#   my $count = 0;

#   # sparse track should be 1 based
#   # we have a method ->zeroBased, but in practice I find it more confusing to use
#   my $based = $self->based;

#   my $delimiter = $self->delimiter;

#   MCE::Loop::init {
#     chunk_size => 2e8, #read in chunks of 200MB
#     max_workers => 32,
#     use_slurpio => 1,
#     gather => \&writeToDatabase,
#   };

#   mce_loop_f {
#     my ($mce, $slurp_ref, $chunk_id) = @_;

#     my @lines;

#     open my $MEM_FH, '<', $slurp_ref;
#     binmode $MEM_FH, ':raw';
#     while (<$MEM_FH>) { push @lines, $_; }
#     close   $MEM_FH;

#     # storing
#     # chr => {
#       #pos => {
#     #    $self->dbName => [val1, val2, val3]
#     #  }
#     #}
#     my %out;

#     #count number of positions recorded for each chr  so that 
#     #we can comply with $self->commitEvery
#     my %count;

#     LINE_LOOP: for my $line (@lines) {
#       #wantedChr means user has asked for just one chromosome
#       if($self->wantedChr && index($line, $self->wantedChr) == -1) {
#         next LINE_LOOP;
#       }

#       chomp $line;

#       my @sLine = split $delimiter, $line;

#       my $chr = $sLine[0];

#       my $dbPosition = $sLine[1] - $based;
#       #if no single --chr is specified at run time,
#       #check against list of genome_chrs
#       if(!$self->chrIsWanted( $chr ) ) {
#         next;
#       }

#       if(! defined $out{ $chr } ) {
#         undef $out{ $chr };
#         $count{ $sLine[0] } = 0;
#       }

#       #if this chr has more than $self->commitEvery records, put it in db
#       if( $count{ $chr } == $self->commitEvery ) {
#         MCE->gather($self, { $chr => $out{ $chr } } );
        
#         undef $out{ $chr };
#         $count{ $chr } = 0;
#       }

#       $out{ $chr }{ $dbPosition } = $self->prepareData( [$sLine[2], $sLine[3], $sLine[4]] );
#       $count{ $chr }++;
#     }

#     # http://www.perlmonks.org/?node_id=1110235
#     if(%out) {
#       MCE->gather($self, \%out);
#     }

#     undef %out;
#     undef %count;
#   } $fh;

#   $self->log('info', 'finished building: ' . $self->name);
# }

sub writeToDatabase {
  my ($self, $resultRef) = @_;

  for my $chr (keys %$resultRef) {
    if( %{ $resultRef->{$chr} } ) {
      $self->dbPatchBulkArray($chr, $resultRef->{$chr} );
    }
  }

  undef $resultRef;
}

__PACKAGE__->meta->make_immutable;
1;
