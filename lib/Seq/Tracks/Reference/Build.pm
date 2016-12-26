use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Reference::Build;

our $VERSION = '0.001';

# ABSTRACT: Builds a plain text genome used for binary genome creation
# VERSION

use Mouse 2;
use namespace::autoclean;
extends 'Seq::Tracks::Build';

use Seq::Tracks::Reference::MapBases;

use Parallel::ForkManager;
use DDP;

my $baseMapper = Seq::Tracks::Reference::MapBases->new();

sub buildTrack {
  my $self = shift;

  my $headerRegex = qr/\A>([\w\d]+)/;
  my $dataRegex = qr/(\A[ATCGNatcgn]+)\z/xms;

  my $pm = Parallel::ForkManager->new($self->max_threads);
  for my $file ( $self->allLocalFiles ) {
    # Expects 1 chr per file for n+1 files, or all chr in 1 file
    # Single writer to reduce copy-on-write db inflation
    $pm->start($file) and next;
      my $fh = $self->get_read_fh($file);

      my %data;
      my $count = 0;

      my $wantedChr;

      my $chrPosition = $self->based;

      # Record which chromosomes we've worked on
      my %visitedChrs;
      FH_LOOP: while ( my $line = $fh->getline() ) {
        #super chomp; also helps us avoid weird characters in the fasta data string
        $line =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between
        
        #could do check here for cadd default format
        #for now, let's assume that we put the CADD file into a wigfix format
        if ( $line =~ m/$headerRegex/ ) { #we found a wig header
          my $chr = $1;

          if(!$chr) { $self->log('fatal', 'Require chr in fasta file headers'); }
          
          # Our first header, or we found a new chromosome
          if( ($wantedChr && $wantedChr ne $chr) || !$wantedChr) {
            if(%data){
              # If user had previously found a wanted chr, but then switched
              # Means it's a multi-fasta file; if !$chrPerFile a regular file was expected
              # Means positions could be off, if chrs shared between files
              if($wantedChr && !$self->chrPerFile) {
                $self->log('warn', " Expected fasta, found multi-fasta");
              }

              #so let's write whatever we have for the previous chr
              $self->db->dbPatchBulkArray($wantedChr, \%data );

              #since this is new, let's reset our data and count
              #we've already updated the chrPosition above
              undef %data;
              $count = 0;
            }

            undef $wantedChr;
            if( $self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr) ) {
              $wantedChr = $chr;
            }
          }

          # We expect either one chr per file, or a multi-fasta file
          if(!$wantedChr) {
            if($self->chrPerFile) {
              last FH_LOOP;
            }
            next FH_LOOP;
          } 

          $visitedChrs{$wantedChr} = 1;

          # Restart chrPosition count at 0, since assemblies are zero-based ($self->based defaults to 0)
          # (or something else if the user based: allows non-reference fasta-formatted sources)
          $chrPosition = $self->based;

          #don't store the header line
          next;
        }

        # If !$wantedChr we're likely in a mult-fasta file; could warn, but that spoils multi-threaded reads
        if ( !$wantedChr ) {
          next;
        }

        if( $line =~ $dataRegex ) {
          # Store the uppercase bases; how UCSC does it, how people likely expect it
          for my $char ( split '', uc($1) ) {
            $data{$chrPosition} = $self->prepareData( $baseMapper->baseMap->{$char} );
	    
	    #if($chrPosition >= 42780001) {
	    #	say "$wantedChr:$chrPosition == $char";
            #}

	    #must come after, to not be 1 off; assumes fasta file is sorted ascending contiguous 
            $chrPosition++; 

            #Count number of entries recorded; write to DB if it's over the limit
            if($count >= $self->commitEvery) {
              $self->db->dbPatchBulkArray($wantedChr, \%data);
              
              undef %data;
              $count = 0;

              #don't reset chrPosition, or wantedChr, because chrPosition is
              #continuous from the previous position in a fixed step file
              #and we haven't changed chromosomes
            }

            $count++;
          }
        }
      }

      # leftovers
      if( %data ) {
        if(!$wantedChr) {
         return $self->log('fatal', "@ end of $file, but no wantedChr and data");
        }

        $self->db->dbPatchBulkArray($wantedChr, \%data );
      }

      # Record completion. Safe because detected errors throw, kill process
      foreach ( keys %visitedChrs ) {
        $self->completionMeta->recordCompletion($_);
      }

    #exit with exit code 0; this only happens if successfully completed
    $pm->finish(0);
  }

  # Check exit codes for succses; 0 indicates success
  my @failed;
  $pm->run_on_finish( sub {
    my ($pid, $exitCode, $fileName, $exit_signal, $core_dump, $statementRef) = @_;

    if($exitCode != 0) {
      my $statement = defined $statementRef ? ${$statementRef} : "";
      
      push @failed, "Got exitCode $exitCode for $fileName, due to: $statement";
      
      $self->log('error', "Got exitCode $exitCode for $fileName: $statement");
    } else {
      $self->log('info', "Got exitCode $exitCode for $fileName");
    }
  });

  $pm->wait_all_children;
  
  # Prevents weird "Ooops! Destryoing active environment" and Segmentation Faults
  # after db opened
  $self->db->cleanUp();
  
  #explicit success
  return @failed == 0 ? 0 : (\@failed, 255);
};

__PACKAGE__->meta->make_immutable;

1;
