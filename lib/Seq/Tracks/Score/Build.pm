use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Score::Build;

our $VERSION = '0.001';

# ABSTRACT: Build a sparse track file
# VERSION

use Mouse 2;

use namespace::autoclean;
use Parallel::ForkManager;
use DDP;
use POSIX qw/abs/;

extends 'Seq::Tracks::Build';

use Seq::Tracks::Score::Build::Round;

my $rounder = Seq::Tracks::Score::Build::Round->new();
# score track could potentially be 0 based
# http://www1.bioinf.uni-leipzig.de/UCSC/goldenPath/help/wiggle.html
# if it is the BED format version of the WIG format.
has '+based' => (
  default => 1,
);

sub buildTrack{
  my $self = shift;

  my $fStep = 'fixedStep';
  my $vStep = 'variableStep';
  my $headerRegex = qr/^($fStep|$vStep)\s+chrom=(\S+)\s+start=(\d+)\s+step=(\d+)/;
    
  my @allChrs = $self->allLocalFiles;
  my $chrPerFile = @allChrs > 1 ? 1 : 0;
  
  #Can't just set to 0, because then the completion code in run_on_finish won't run
  my $pm = Parallel::ForkManager->new(scalar @allChrs);

  for my $file ( $self->allLocalFiles ) {
    $pm->start($file) and next; 
      unless ( -f $file ) {
        return $self->log('fatal', "ERROR: cannot find $file");
      }

      my $fh = $self->get_read_fh($file);

      my %data = ();
      my $count = 0;

      my $wantedChr;
      my $chrPosition; # absolute by default, 0 index
      
      my $step;
      my $stepType;

      my $based = $self->based;

      # Which chromosomes we've seen, for recording completionMeta
      my %visitedChrs; 

      FH_LOOP: while ( <$fh> ) {
        #super chomp; #trim both ends, but not what's in between
        $_ =~ s/^\s+|\s+$//g; 

        if ( $_ =~ m/$headerRegex/ ) {
          my $chr = $2;

          $step = $4;
          $stepType = $1;

          my $start = $3;
          
          if(!$chr && $step && $start && $stepType) {
           return $self->log('fatal', 'Require chr, step, start, 
              and step type fields in wig header');
          }

          if($stepType eq $vStep) {
            return $self->log('fatal', 'variable step not currently supported');
          }

          if(!$wantedChr || ( $wantedChr && $wantedChr ne $chr) ) {
            if($wantedChr){  $self->log('fatal', "Expected one chr per file, but found > 1 chr"); }

            # we found something new, so let's write if we have reason
            if(%data) {
              $self->db->dbPatchBulkArray($wantedChr, \%data);
            }
             
            #since this is new, let's reset our data and count
            undef %data;
            $count = 0;

            #and figure out if we want the current chromosome
            $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;

            if($self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr)) {
              $wantedChr = $chr;
            } else {
              $wantedChr = undef;
            }
          }

          #use may give us one or many files
          if(!$wantedChr) {
            if($chrPerFile) {
              last FH_LOOP;
            }
            next FH_LOOP;
          } 

          # take the offset into account
          $chrPosition = $start - $based;

          # Record what we've seen
          $visitedChrs{$wantedChr} = 1;

          #don't store the header in the database
          next;
        }

        # there could be more than one chr defined per file, just skip 
        # until we get to what we want
        if ( !$wantedChr ) {
          next;
        }
        
        $data{$chrPosition} = $self->prepareData( $rounder->round($_) );

        #this must come AFTER we store the position, since we have a starting pos
        $chrPosition += $step;

        $count++;
        if($count >= $self->commitEvery) {
          $self->db->dbPatchBulkArray($wantedChr, \%data );
          %data = ();
          $count = 0;

          #don't reset chrPosition, or wantedChr, because chrPosition is
          #continuous from the previous position in a fixed step file
          #and we haven't changed chromosomes
        }
      }

      # leftovers
      if( %data ) {
        if(!$wantedChr) {
          return $self->log('fatal', "at end of $file no wantedChr && data found");
        }

        $self->db->dbPatchBulkArray($wantedChr, \%data );
      }

      # Record completion. Safe because detected errors throw, kill process
      foreach (keys %visitedChrs) {
        $self->completionMeta->recordCompletion($_);
      }

    $pm->finish(0);
  }

  $pm->run_on_finish(sub {
    my ($pid, $exitCode, $fileName) = @_;

    if($exitCode != 0) { $self->log('fatal', "Failed to complete ". $self->name ." due to: $exitCode in $fileName processing"); }

    $self->log('debug', "Got exitCode $exitCode for $fileName");
  });
  
  $pm->wait_all_children;
};

__PACKAGE__->meta->make_immutable;

1;