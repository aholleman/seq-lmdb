use 5.10.0;
use strict;
use warnings;

#old GenomeSizedTrackStr
package Seq::Tracks::Reference::Build;

our $VERSION = '0.001';

# ABSTRACT: Builds a plain text genome used for binary genome creation
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Types::Reference>

  Builds a reference genome

Extended in: None

=cut

use Moose 2;
use MCE::Loop;

use DDP;

use namespace::autoclean;

extends 'Seq::Tracks::Build';

sub buildTrack {
  my $self = shift;

  my $headerRegex = qr/\A>([\w\d]+)/;
  my $dataRegex = qr/(\A[ATCGNatcgn]+)\z/xms;

  my @allLocalFiles = $self->all_local_files;

  my $chrPerFile = @allLocalFiles > 1 ? 1 : 0;

  #don't let the users change this (at least for now)
  #we should only allow them to tell us how to get their custom tracks to 0 based
  my $based = 0; #$self->based;

  #simple forking; could do something more involvd if we had guarantee
  #that a single file would be in order of chr
  #expects that if n+1 files, each file has a single chr (one writer per chr)
  #important, because we'll probably get slower writes due to locks otherwise
  #unless we pass the slurped file to the fork, it doesn't seem to actually
  MCE::Loop->init({
    max_workers => 26,
    chunk_size => 1,
    user_end => sub {
      #indicates success
      return 1;
    },
  });

  mce_loop {
    my $file = $_;

    if ( ! -f $file ) {
      $self->log('fatal', "ERROR: cannot find $file");
    }
    my $fh = $self->get_read_fh($file);

    my %data = ();
    my $count = 0;

    my $wantedChr;

    # we store the 0 indexed position, or something else if the user
    # specifies something else; to allow fasta-formatted data sources that
    # aren't reference
    my $chrPosition = $based;
    
    #record which chromosomes we completed, so as to write their success
    my %visitedChrs;
    FH_LOOP: while ( <$fh> ) {
      #super chomp; also helps us avoid weird characters in the fasta data string
      $_ =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between

      #could do check here for cadd default format
      #for now, let's assume that we put the CADD file into a wigfix format
      if ( $_ =~ m/$headerRegex/ ) { #we found a wig header
        my $chr = $1;

        if(!$chr) {
          #should die after error, return is just to indicate intention
          $self->log('fatal', 'Require chr in fasta file headers');
        }

        
        if($wantedChr) {
          #this is old news to us, so we have nothing to do in this header
          #row
          if($wantedChr eq $chr) {
            next;
          }

          #ok, we found something new, 
          if($wantedChr ne $chr){
            #so let's write whatever we have for the previous chr
            $self->dbPatchBulk($wantedChr, \%data );

            #since this is new, let's reset our data and count
            #we've already updated the chrPosition above
            %data = ();
            $count = 0;

            #and figure out if we want the current chromosome
            $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;

            if($wantedChr && !$self->itIsOkToProceedBuilding($wantedChr) ) {
              undef $wantedChr;
            }
          }
        } else {
          $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;

          if($wantedChr && !$self->itIsOkToProceedBuilding($wantedChr) ) {
            undef $wantedChr;
          }
        }

        #this allows us to use a single fasta file as well
        #although in the current setup, using such a file will prevent
        #forking use (since we read the file in the fork)
        #we could always spawn a fork within the fork
        #if we're expecting one chr per file, no need to read through the
        #rest of the file if we don't want the current header chr
        if(!$wantedChr) {
          if($chrPerFile) {
            last FH_LOOP;
          }
          next FH_LOOP;
        } 

        $visitedChrs{$wantedChr} = 1;
        #restart chrPosition count at 0, since we're storing 0 indexed pos
        $chrPosition = $based;
      }

      #don't die if no wanted chr; could be some harmless mistake
      #like a blank line on the first, instead of a header
      #but the user should know, because it portends other issues
      if ( !$wantedChr ) {
        $self->log('warn', "No wanted chr after first line " .
          'could be malformed reference file');
        next;
      }
      
      if( $_ =~ $dataRegex ) {
        #store the uppercase versions; how UCSC does it, how people likely
        #expect it, and remove the need to do it at annotation time
        for my $char ( split '', uc($1) ) {
          #we always store on position
          #it could als make sense for prepareData to handle the key (chrPosition)
          #since this needs to be uniform across most tracks
          #but this is a bit easier to understand for me:
          $data{$chrPosition} = $self->prepareData($char);

          #must come after, to not be 1 off; 
          #assumes fasta file is properly sorted, so contiguous 
          $chrPosition++; 

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

    #we're done with the input file, 
    if( %data ) {
      if(!$wantedChr) { #sanity check, 'error' log dies
       return $self->log('fatal', "@ end of $file, but no wantedChr and data");
      }
      #and we could still have some data to write
      $self->dbPatchBulk($wantedChr, \%data );
    }

    foreach ( keys %visitedChrs ) {
      $self->recordCompletion($_);
    }
  } @allLocalFiles;
};

#TODO: need to catch errors if any
#not 100% sure how to do this with the present LMDB API without losing perf
state $metaKey = 'completed';

#hash of completion status
state $completed;
sub recordCompletion {
  my ($self, $chr) = @_;
  
  # overwrite any existing entry for $chr
  my $err = $self->dbPatchMeta($self->name, $metaKey, {
    $chr => 1,
  }, 1 );

  if(!$err) {
    $completed->{$chr} = 1;
    $self->log('debug', "recorded the completion of $chr (set to 1)"
      . " for the " . $self->name . " track");
  } else {
    $self->log('error', $err);
  }
};

sub eraseCompletion {
  my ($self, $chr) = @_;
  
  # overwrite any existing entry for $chr
  my $err = $self->dbPatchMeta($self->name, $metaKey, {
    $chr => 0,
  }, 1 );

  if(!$err) {
    $completed->{$chr} = 0;
    $self->log('debug', "erased the completion of $chr (set to 0)"
      . " for the " . $self->name . " track");
  } else {
    $self->log('error', $err);
  }
};

sub isCompleted {
  my ($self, $chr) = @_;

  if(defined $completed->{$chr} ) {
    return $completed->{$chr};
  }

  my $allCompleted = $self->dbReadMeta($self->name, $metaKey);
  
  if( defined $allCompleted && defined $allCompleted->{$chr} 
  && $allCompleted->{$chr} == 1 ) {
    $completed->{$chr} = 1;
  } else {
    $completed->{$chr} = 0;
  }
  
  return $completed->{$chr};
};


sub itIsOkToProceedBuilding {
  my ($self, $chr) = @_;
  
  if($self->isCompleted($chr) ) {
    if(!$self->overwrite) {
      $self->log('debug', "$chr is recorded as completed for " . $self->name . ". Since
        overwrite isn't set, won't build the $chr " . $self->name . " db");
      return;
    }
    $self->eraseCompletion($chr);
    $self->log('debug', "$chr is recorded as completed for " . $self->name . ". Since
        overwrite is set, will now build the $chr " . $self->name . " db");
  }
  return 1;
}
__PACKAGE__->meta->make_immutable;

1;



#many tracks require reference tracks
#so we take an extra check that it hasn't been built yet
# if($wantedChr && (!$self->overwrite && $self->isCompleted($wantedChr) ) ) {
#   undef $wantedChr;
# }