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

has '+based' => (
  default => 1,
);

my $pm = Parallel::ForkManager->new(25);
sub buildTrack{
  my $self = shift;

  #TODO: use cursor to read first and last position;
  #compare these to first and last entry in the resulting string
  #if identical, and identical length for that chromosome, 
  #don't do any writing.
  $self->tee_logger('info', "starting to build " . $self->name );

  my $fStep = 'fixedStep';
  my $vStep = 'variableStep';
  my $headerRegex = qr/^($fStep|$vStep)\s+chrom=(\S+)\s+start=(\d+)\s+step=(\d+)/;
  
  my $chrPerFile = scalar $self->all_local_files > 1 ? 1 : 0;

  # score track could potentially be 0 based
  # http://www1.bioinf.uni-leipzig.de/UCSC/goldenPath/help/wiggle.html
  # if it is the BED format version of the WIG format.
  # BED doesn't have a header line, and we don't currently support it, but want flex.
  my $based = $self->based;
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
      my $chrPosition; # absolute by default, 0 index
      
      my $step;
      my $stepType;

      FH_LOOP: while ( <$fh> ) {
        chomp $_;
        $_ =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between

        #could do check here for cadd default format
        #for now, let's assume that we put the CADD file into a wigfix format
        if ( $_ =~ m/$headerRegex/ ) { #we found a wig header
          my $chr = $2;

          $step = $4;
          $stepType = $1;

          my $start = $3;
          
          if(!$chr && $step && $start && $stepType) {
            $self->tee_logger('error', 'Require chr, step, start, 
              and step type fields in wig header');
          }

          if($stepType eq $vStep) {
            $self->tee_logger('error', 'variable step not currently supported');
          }

          #set the chrPosition early, because otherwise we need to do 2x
          #and make this 0 index
          $chrPosition = $start - $based;

          if ($wantedChr && $wantedChr eq $chr) {
            next;
          }

          #ok, we found something new, so let's write whatever we have for the
          #previous chr
          if($wantedChr && $wantedChr ne $chr) {
            $self->dbPatchBulk($wantedChr, \%data );
          }

          #since this is new, let's reset our data and count
          #we've already updated the chrPosition above
          %data = ();
          $count = 0;
          
          #chr is new and wanted
          if ( $self->chrIsWanted($chr) ) {
            $wantedChr = $chr;
            next;
          }

          # chr isn't wanted if we got here
          $self->tee_logger('warn', "skipping unrecognized chromsome: $chr");

          #so let's erase the remaining data associated with this chr
          undef $wantedChr;
          undef $chrPosition;

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
          $self->tee_logger('error', "@ end of $file no wantedChr && data found");
        }

        $self->dbPatchBulk($wantedChr, \%data );

        #now we're done with the process, and memory gets freed
      }
    $pm->finish;
  }
  $pm->wait_all_children;

  $self->tee_logger('info', 'finished building score track: ' . $self->name);
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
