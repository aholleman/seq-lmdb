use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::ScoreTrack::Build;

our $VERSION = '0.001';

# ABSTRACT: Base class for sparse track building
# VERSION

=head1 DESCRIPTION
  
  @class Seq::Build::SparseTrack
  # Accepts a wig format file. For now, only fixed step is supported
  @example

Used in:
=for :list
*

Extended by:
=for :list
* Seq/Build/GeneTrack.pm
* Seq/Build/TxTrack.pm

=cut

use Moose 2;

use namespace::autoclean;
use Parallel::ForkManager;
use DDP;

extends 'Seq::Tracks::Build';
#We could think about how to meaningfully combine these two
#they're extremely similar
#extends 'Seq::Tracks::Reference::Build';
with 'Seq::Tracks::Build::Interface';
my $pm = Parallel::ForkManager->new(6);
sub buildTrack{
  my $self = shift;

  #TODO: use cursor to read first and last position;
  #compare these to first and last entry in the resulting string
  #if identical, and identical length for that chromosome, 
  #don't do any writing.
  $self->tee_logger('info', "starting to build score track $self->name" );

  my $fStep = 'fixedStep';
  my $vStep = 'variableStep';
  my $headerRegex = qr/^($fStep|$vStep)\s+chrom=(\S+)\s+start=(\d+)\s+step=(\d+)/;
  
  my $chrPerFile = scalar $self->all_local_files > 1 ? 1 : 0;

  for my $file ( $self->all_local_files ) {
    unless ( -f $file ) {
      $self->tee_logger('error', "ERROR: cannot find $file");
    }
    #simple forking; could do something more involvd if we had guarantee
    #that a single file would be in order of chr
    #expects that if n+1 files, each file has a single chr (one writer per chr)
    #important, because we'll probably get slower writes due to locks otherwise
    #unless we pass the slurped file to the fork, it doesn't seem to actually
    $pm->start and next; 
      my $tfile = $file;
      #say "entering fork with $file";
      #my @lines = $self->get_file_lines($file);
      my $fh = $self->get_read_fh($file);
      my %data = ();
      my $wantedChr;
      my $chr;
      my $chrPosition; # absolute by default, 0 index
      my $count = 0;
      my $step;
      my $stepType;

      FH_LOOP: while ( <$fh> ) {
        #already chomped chomp $_;
        $_ =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between

        #could do check here for cadd default format
        #for now, let's assume that we put the CADD file into a wigfix format
        if ( $_ =~ m/$headerRegex/ ) { #we found a wigfix
          #say "read $_";
          $stepType = $1;
          $chr = $2;
          my $start = $3;
          $step = $4;

          if(!$chr && $step && $start && $stepType) {
            $self->tee_logger('error', 'Require chr, step, start, 
              and step type fields in wig header');
          }
          #this will work better if the wigfix file is sorted by chr
          #not sure what happens if two writers attempt 
          #but I hope the 2nd would wait for the first to finish, instead of just dying
          if(%data) {
            if(!$wantedChr) {
              %data = ();
            } elsif($wantedChr ne $chr) {
              #it's a new chr, so let's write whatever we have left
              #in case the file has more than one chr
              $self->dbPatchBulk($wantedChr, \%data );
              #erase the chr, we'll check below if we want the new one
              %data = ();
              undef $wantedChr;
              undef $chrPosition;
            }
          }

          if ( $self->chrIsWanted($chr) ) {
            $wantedChr = $chr;
            #0 index positions
            $chrPosition = $start - 1;
          } else {
            $self->tee_logger('warn', "skipping unrecognized chromsome: $chr");
            
            %data = ();
            undef $wantedChr;
            undef $chrPosition;

            if ( $chrPerFile ) {
              last FH_LOOP; 
            }
          }
        } elsif ( $wantedChr ) {
          if($stepType eq $vStep) {
            $self->tee_logger('error', 'variable step not currently supported');
          }

          $chrPosition += $step;
          $data{$chrPosition} = $self->prepareData($_);

          $count++;
          if($count >= $self->commitEvery) {
            $self->dbPatchBulk($wantedChr, \%data );
            %data = ();
            $count = 0;
            #don't reset chrPosition, or wantedChr of course
          }
        }
      }

      if( %data ) {
        if(!($wantedChr && %data) ) { #sanity check
          $self->tee_logger('error', 'at the end of the file
            wantedChr and/or data not found');
        }

        $self->dbPatchBulk($wantedChr, \%data );

        #shouldn't be necesasry, just in case
        undef %data;
        undef $wantedChr; 
      }
    $pm->finish;
  }
  $pm->wait_all_children;

  $self->tee_logger('info', 'finished building string genome');
};

#Because of linux copy-on-write, this is actually very memory efficient
#however, "top" will show the same initial memory usage between the two processes
#(parent and child), which may seem like a gigantic memory leak
#http://serverfault.com/questions/440115/how-do-you-measure-the-memory-footprint-of-a-set-of-forked-processes
# sub _write {
#   my $self = shift;
#   $pm->start and return; #$self->tee_logger('warn', "couldn't write $_[0] Reference track");
#     my ($chr, $dataHref) = @_;
    
#     say "entering fork for chr $chr"; #if $self->debug; #TODO: remove
#     # say "data is";
#     # p $dataHref;
#     $self->writeAllData( $chr, $dataHref );
  
#     $pm->finish;
# }


__PACKAGE__->meta->make_immutable;

1;
