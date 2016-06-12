use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Score::Build;

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
use MCE::Loop;

use DDP;

extends 'Seq::Tracks::Build';
#We could think about how to meaningfully combine these two
#they're extremely similar
#extends 'Seq::Tracks::Reference::Build';
with 'Seq::Role::IO';

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

  my $fStep = 'fixedStep';
  my $vStep = 'variableStep';
  my $headerRegex = qr/^($fStep|$vStep)\s+chrom=(\S+)\s+start=(\d+)\s+step=(\d+)/;
  
  my $chrPerFile = scalar $self->allLocalFiles > 1 ? 1 : 0;

  # score track could potentially be 0 based
  # http://www1.bioinf.uni-leipzig.de/UCSC/goldenPath/help/wiggle.html
  # if it is the BED format version of the WIG format.
  # BED doesn't have a header line, and we don't currently support it, but want flex.
  #however, while subtracting this number may be faster than a function call
  #I worry about maintainability
  #my $based = $self->based;
  for my $file ( $self->all_local_files ) {
    #simple forking; could do something more involvd if we had guarantee
    #that a single file would be in order of chr
    #expects that if n+1 files, each file has a single chr (one writer per chr)
    #important, because we'll probably get slower writes due to locks otherwise
    #unless we pass the slurped file to the fork, it doesn't seem to actually
    $pm->start and next; 

    unless ( -f $file ) {
      return $self->log('fatal', "ERROR: cannot find $file");
    }

    MCE::Loop::init({
      chunk_size => 'auto',
      use_slurpio => 1,
      gather => sub {
        my ($chr, $data) = @_;
        $self->dbPatchBulk($chr, $data);
      },
    });

    
    #say "entering fork with $file";
    #my @lines = $self->get_file_lines($file);
    my $fh = $self->get_read_fh($file);

    my %data = ();
    my $count = 0;

    my $wantedChr;
    my $chrPosition; # absolute by default, 0 index
    
    my $step;
    my $stepType;

    # score track could potentially be 0 based
    # http://www1.bioinf.uni-leipzig.de/UCSC/goldenPath/help/wiggle.html
    # if it is the BED format version of the WIG format.
    # BED doesn't have a header line, and we don't currently support it, but want flex.
    my $based = $self->based;

    mce_loop_f {
      my ($mce, $slurp_ref, $chunk_id) = @_;
      open my $MEM_FH, '<', $slurp_ref;
      binmode $MEM_FH, ':raw';

      FH_LOOP: while (<$MEM_FH>) {
        #super chomp; helps us avoid unexpected whitespace on either side
        #of the data; since we expect one field per column, this should be safe
        $_ =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between

        #could do check here for cadd default format
        #for now, let's assume that we put the CADD file into a wigfix format
        if ( $_ =~ m/$headerRegex/ ) { #we found a wig header
          $stepType = $1;

          my $chr = $2;

          my $start = $3;

          $step = $4;
          
          if(!$chr && $step && $start && $stepType) {
           return $self->log('fatal', 'Require chr, step, start, 
              and step type fields in wig header');
          }

          if($stepType eq $vStep) {
            return $self->log('fatal', 'variable step not currently supported');
          }

          #set the chrPosition early, because otherwise we need to do 2x
          #and make this 0 index
          $chrPosition = $start - $based;

          #If the chromosome is new, write any data we have & see if we want new one
          if($wantedChr ) {
            if($wantedChr ne $chr) {
              #ok, we found something new, or this is our first time getting a $wantedChr
              #so let's write whatever we have for the previous wanted chr
              if (%data) {
                MCE->gather($wantedChr, \%data);
               
                undef %data;
                $count = 0;
              }
              
              $wantedChr = $self->chrIsWanted($chr) || undef;
            }
          } else {
            $wantedChr = $self->chrIsWanted($chr) || undef;
          }
          
          if(!$wantedChr) {
            # chr isn't wanted if we got here
            # so leave this loop if we have one chr per file
            # else we have one file, so abort this process
            if($chrPerFile) {
              $mce->abort;
            }
            # else just move on to the next line (explict next for clarity)
            next FH_LOOP;
          }
        }

        #don't die if no wanted chr; could be some harmless mistake
        #like a blank line on the first, instead of a header
        #but the user should know, because it portends other issues
        if ( !$wantedChr ) {
          $self->log('warn', "No wanted chr found, after first line " .
            'could be malformed wig file');
          next;
        }
        
        $data{$chrPosition} = $self->prepareData($_);

        #this must come AFTER we store the position, since we have a starting pos
        $chrPosition += $step;

        $count++;

        if($count >= $self->commitEvery) {
          MCE->gather($wantedChr, \%data );

          undef %data;
          $count = 0;

          #don't reset chrPosition, or wantedChr, because chrPosition is
          #continuous from the previous position in a fixed step file
          #and we haven't changed chromosomes
        }
      }

      #we're done with this input file chunk and we could still have some data to write
      if( %data ) {
        if(!$wantedChr) { #sanity check, 'error' will die
          return $self->log('fatal', "at end of $file no wantedChr && data found");
        }

        MCE->gather($wantedChr, \%data );

        #now we're done with the process, and memory gets freed
        #but just in case
        undef %data;
        undef $wantedChr
      }
    } $fh;

    MCE::Loop::finish;
    $pm->finish;
  }

  $pm->wait_all_children;
};

__PACKAGE__->meta->make_immutable;

1;
