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
use Parallel::ForkManager;

use DDP;

use namespace::autoclean;

extends 'Seq::Tracks::Build';

my $pm = Parallel::ForkManager->new(26);

sub buildTrack {
  my $self = shift;

  my $headerRegex = qr/\A>([\w\d]+)/;
  my $dataRegex = qr/(\A[ATCGNatcgn]+)\z/xms;

  my @allLocalFiles = $self->allLocalFiles;

  my $chrPerFile = @allLocalFiles > 1 ? 1 : 0;

  #don't let the users change this (at least for now)
  #we should only allow them to tell us how to get their custom tracks to 0 based
  #default of $self->based is 0
  my $based = $self->based;

  for my $file (@allLocalFiles) {
    $pm->start and next;

    if ( ! -f $file ) {
      $self->log('fatal', "ERROR: cannot find $file");
    }

    my $fh = $self->get_read_fh($file);

    my $firstLine = <$fh>;

    my $chr;

    $firstLine =~ s/^\s+|\s+$//g;

    if ( $firstLine =~ m/$headerRegex/ ) {
      $chr = $1;
    }

    if(!$chr) {
      #should die after error, return is just to indicate intention
      $self->log('fatal', 'Require chr in fasta file headers');
    }

    #record which chromosomes we completed, so as to write their success
    my %visitedChrs;

    MCE::Loop::init({
      use_slurpio => 1,
      max_workers => 8,
      gather => sub {
        my ($chr, $data) = @_;

        $self->dbPatchBulk($chr, $data);

        $visitedChrs{$chr} = 1;
      },
      user_end => sub {
        foreach ( keys %visitedChrs ) {
          $self->recordCompletion($_);
        }
      }
    });

    mce_loop_f {
      my ($mce, $slurp_ref, $chunk_id) = @_;
      open my $MEM_FH, '<', $slurp_ref;
      binmode $MEM_FH, ':raw';

      my %data = ();
      my $count = 0;

      my $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;

      if(!$wantedChr || !$self->itIsOkToProceedBuilding($wantedChr)) {
        #gets sent to user_end
        $mce->exit();
      }

      # we store the 0 indexed position, or something else if the user
      # specifies something else; to allow fasta-formatted data sources that
      # aren't reference
      my $chrPosition = $based;
      
      FH_LOOP: while (<$MEM_FH>) {
        #super chomp; also helps us avoid weird characters in the fasta data string
        $_ =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between

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
              MCE->gather($wantedChr, \%data );
              
              undef %data;
              $count = 0;

              #don't reset chrPosition, or wantedChr, because chrPosition is
              #continuous from the previous position in a fixed step file
              #and we haven't changed chromosomes
            }
          }
        }
        #end reading the chunk
      }

      #we're done with the input file, 
      if( %data ) {
        if(!$wantedChr) { #sanity check, 'error' log dies
         return $self->log('fatal', "@ end of $file, but no wantedChr and data");
        }
        #and we could still have some data to write
        MCE->gather($wantedChr, \%data );
      }
      #move on to next chunk
    } $fh;

    MCE::Loop::finish;
    $pm->finish;
  }

  $pm->wait_all_children;
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