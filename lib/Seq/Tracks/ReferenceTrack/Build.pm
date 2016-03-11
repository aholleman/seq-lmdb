use 5.10.0;
use strict;
use warnings;

#old GenomeSizedTrackStr
package Seq::Tracks::ReferenceTrack::Build;

our $VERSION = '0.001';

# ABSTRACT: Builds a plain text genome used for binary genome creation
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Types::Reference>

  TODO: Add description
  Stores a String representation of a genome, as well as the length of each chromosome in the genome.
  Is a single responsibility class with no public functions.

Used in:
=for :list
* Seq/Build/SparseTrack
* Seq/Build

Extended in: None

=cut

use Moose 2;
use Parallel::ForkManager;
use DDP;

use namespace::autoclean;
extends 'Seq::Tracks::Build';
with 'Seq::Tracks::Build::Interface';

# TODO: globally manage forks, so we don't get some crazy resource use
with 'Seq::Tracks::Build::Interface';

my $pm = Parallel::ForkManager->new(8);

sub buildTrack{
  my $self = shift;

  #TODO: use cursor to read first and last position;
  #compare these to first and last entry in the resulting string
  #if identical, and identical length for that chromosome, 
  #don't do any writing.
  $self->tee_logger('info', "starting to build " . $self->name );

  my $fStep = 'fixedStep';
  my $vStep = 'variableStep';
  my $headerRegex = qr/\A>([\w\d]+)/;
  my $dataRegex = qr/(\A[ATCGNatcgn]+)\z/xms;

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
      #say "entering fork with $file";
      #my @lines = $self->get_file_lines($file);
      my $fh = $self->get_read_fh($file);

      my %data = ();
      my $count = 0;

      my $wantedChr;

      # we store the 0 indexed position
      my $chrPosition = 0;
      
      FH_LOOP: while ( <$fh> ) {
        chomp $_;
        $_ =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between

        #could do check here for cadd default format
        #for now, let's assume that we put the CADD file into a wigfix format
        if ( $_ =~ m/$headerRegex/ ) { #we found a wig header
          my $chr = $1;

          if(!$chr) {
            $self->tee_logger('error', 'Require chr in fasta file headers');
          }

          if ($wantedChr && $wantedChr eq $chr) {
            next;
          }

          #ok, we found something new, so let's write whatever we have for the
          #previous chr
          if($wantedChr && $wantedChr ne $chr) {
            say "chr $chr does not equal $wantedChr" if $self->debug;

            $self->dbPatchBulk($wantedChr, \%data );
          }

          #since this is new, let's reset our data and count
          #we've already updated the chrPosition above
          %data = ();
          $count = 0;
          
          #chr is new and wanted
          #this allows us to use a single fasta file as well
          #although in the current setup, using such a file will prevent
          #forking use (since we read the file in the fork)
          #we could always spawn a fork within the fork
          if ( $self->chrIsWanted($chr) ) {
            $wantedChr = $chr;
            next;
          }

          # chr isn't wanted if we got here
          $self->tee_logger('warn', "skipping unrecognized chromsome: $chr");

          #so let's erase the remaining data associated with this chr
          #restart chrPosition count at 0, since we're storing 0 indexed pos
          undef $wantedChr;
          $chrPosition = 0;

          #if we're expecting one chr per file, no need to read through the
          #rest of the file if we don't want the current header chr
          if ( $chrPerFile ) {
            last FH_LOOP; 
          }
        }

        #don't die if no wanted chr; could be some harmless mistake
        #like a blank line on the first, instead of a header
        #but the user should know, because it portends other issues
        if ( !$wantedChr ) {
          $self->tee_logger('warn', "No wanted chr found, after first line " .
            'could be malformed wig file');
          next;
        }
        
        if( $_ =~ $dataRegex ) {
          for my $char ( split '', $1 ) {
            $chrPosition++;
            $data{$chrPosition} = $self->prepareData($char);
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

        }
      }

      #we're done with the input file, and we could still have some data to write
      if( %data ) {
        if(!$wantedChr) { #sanity check
          $self->tee_logger('error', 'at the end of the file
            wantedChr and/or data not found');
        }

        $self->dbPatchBulk($wantedChr, \%data );

        #shouldn't be necesasry, just in case
        undef %data;
        undef $wantedChr; 
        undef $chrPosition;
        undef $count;
      }
    $pm->finish;
  }
  $pm->wait_all_children;

  $self->tee_logger('info', 'finished building score track: ' . $self->name);
};


__PACKAGE__->meta->make_immutable;

1;
