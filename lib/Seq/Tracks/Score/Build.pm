use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Score::Build;

our $VERSION = '0.001';

# ABSTRACT: Build a sparse track file
# VERSION

use Moose 2;

use namespace::autoclean;
use Parallel::ForkManager;
use DDP;

extends 'Seq::Tracks::Build';
with 'Seq::Role::IO';
  
# score track could potentially be 0 based
# http://www1.bioinf.uni-leipzig.de/UCSC/goldenPath/help/wiggle.html
# if it is the BED format version of the WIG format.
has '+based' => (
  default => 1,
);

my $pm = Parallel::ForkManager->new(26);
sub buildTrack{
  my $self = shift;

  my $fStep = 'fixedStep';
  my $vStep = 'variableStep';
  my $headerRegex = qr/^($fStep|$vStep)\s+chrom=(\S+)\s+start=(\d+)\s+step=(\d+)/;
  
  my $chrPerFile = scalar $self->allLocalFiles > 1 ? 1 : 0;

  for my $file ( $self->allLocalFiles ) {
    $pm->start and next; 
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

      my $firstLine = <$fh>;

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

          if($wantedChr) {
            #ok, we found something new, 
            if($wantedChr ne $chr){
              if(!$chrPerFile) {
                $self->log('fatal', "found a multi-chr bearing input file " .
                  " but expected one chr per file, since multiple files given");
              }

              #so let's write whatever we have for the previous chr
              $self->dbPatchBulk($wantedChr, \%data);

              #since this is new, let's reset our data and count
              #we've already updated the chrPosition above
              undef %data;
              $count = 0;

              #and figure out if we want the current chromosome
              $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;

              # TODO: check if we've built this already, as done with reference
              # if($wantedChr && !$self->itIsOkToProceedBuilding($wantedChr) ) {
              #   undef $wantedChr;
              # }
            }
          } else {
            $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;

            # TODO: check if we've built this already, as done with reference
            # if($wantedChr && !$self->itIsOkToProceedBuilding($wantedChr) ) {
            #   undef $wantedChr;
            # }
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
        }

        # there could be more than one chr defined per file, just skip 
        # until we get to what we want
        if ( !$wantedChr ) {
          next;
        }
        
        $data{$chrPosition} = $self->prepareData($_);

        #this must come AFTER we store the position, since we have a starting pos
        $chrPosition += $step;

        $count++;
        if($count >= $self->commitEvery) {
          $self->dbPatchBulk($wantedChr, \%data );
          %data = ();
          $count = 0;

          #don't reset chrPosition, or wantedChr, because chrPosition is
          #continuous from the previous position in a fixed step file
          #and we haven't changed chromosomes
        }
      }

      #we're done with the input file, and we could still have some data to write
      if( %data ) {
        if(!$wantedChr) { #sanity check, 'error' will die
          return $self->log('fatal', "at end of $file no wantedChr && data found");
        }

        $self->dbPatchBulk($wantedChr, \%data );

        #now we're done with the process, and memory gets freed
      }

    $pm->finish;
  }
  
  $pm->wait_all_children;

  # FINISH THIS; should only return this if it truly did finish all chr 
  return 0;
};

__PACKAGE__->meta->make_immutable;

1;