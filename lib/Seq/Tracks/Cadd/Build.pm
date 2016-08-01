use 5.10.0;
use strict;
use warnings;
  # Adds cadd data to our main database
  # Reads CADD's bed-like format
package Seq::Tracks::Cadd::Build;

use Mouse 2;
extends 'Seq::Tracks::Build';

use DDP;

use Seq::Tracks::Cadd::Order;
use Seq::Tracks::Score::Build::Round;
use Seq::Tracks;

my $rounder = Seq::Tracks::Score::Build::Round->new();

# Cadd tracks seem to be 1 based (not well documented)
has '+based' => (
  default => 1,
);

# CADD files may not be sorted,
has sorted_guaranteed => (is => 'ro', isa => 'Bool', lazy => 1, default => 0);

my $order = Seq::Tracks::Cadd::Order->new();
$order = $order->order;

my $refTrack;
sub BUILD {
  my $self = shift;

  my $tracks = Seq::Tracks->new();
  $refTrack = $tracks->getRefTrackGetter();
}

sub buildTrack {
  my $self = shift;

  my $pm = Parallel::ForkManager->new(scalar @{$self->local_files});
  
  my $columnDelimiter = $self->delimiter;

  for my $file ( @{$self->local_files} ) {
    $pm->start($file) and next;

      my $fh = $self->get_read_fh($file);

      my $versionLine = <$fh>;
      chomp $versionLine;
      
      if( index($versionLine, '## CADD') == - 1) {
        $self->log('fatal', "First line of CADD file is not CADD formatted: $_");
      }

      $self->log("info", "Building ". $self->name . " version: $versionLine using $file");

      # Cadd's columns descriptor is on the 2nd line
      my $headerLine = <$fh>;
      chomp $headerLine;

      # We may have converted the CADD file to a BED-like format, which has
      # chrom chromStart chromEnd instead of #Chrom Pos
      # and which is 0-based instead of 1 based
      # Moving $phastIdx to the last column
      my @headerFields = split $columnDelimiter, $headerLine;

      # Get the last index, that's where the phast column lives https://ideone.com/zgtKuf
      # Can be 5th or 6th column idx. 5th for CADD file, 6th for BED-like file
      my $phastIdx = $#headerFields;

      my $altAlleleIdx = $#headerFields - 2;
      my $refBaseIdx = $#headerFields - 3;

      my $based = $self->based;
      my $isBed;
      
      if(@headerFields == 7) {
        # It's the bed-like format
        $based = 0;
        $isBed = 1;
      }

      # Accumulate 3 lines worth of PHRED scores
      # We cannot assume the CADD file will be properly sorted when liftOver used
      # So checks need to be made
      my %scores;

      my %out;
      my %count;
      my $wantedChr;

      # Track which fields we recorded, to record in $self->completionMeta
      my %visitedChrs = ();

      # Cadd scores can be out of order after liftOver, which means
      # that we may write to the same database from multiple processes
      if(!$self->sorted_guaranteed) {
        # To reduce lock contention (maybe?), reduce database inflation mostly
        $self->commitEvery(1000);
      }
        
      my $lastPosition;
      # File does not need to be sorted by chromosome, but each position
      # must be in a block of 3 (one for each possible allele)
      FH_LOOP: while ( my $line = $fh->getline() ) {
        chomp $line;
        
        my @fields = split $columnDelimiter, $line;

        my $chr = $isBed ? $fields[0] : "chr$fields[0]";

        if( !$wantedChr || ($wantedChr && $wantedChr ne $chr) ) {
          if( defined $wantedChr && defined $out{$wantedChr} && %{ $out{$wantedChr} } ) {
            $self->log('info', "Changed from chr $wantedChr to $chr, writing $wantedChr data");

            $self->db->dbPatchBulkArray( $wantedChr, $out{$wantedChr} );
            
            $count{$wantedChr} = 0; delete $out{$wantedChr};
          }

          if($wantedChr && $self->chrPerFile) {
            $self->log('warn', "Expected 1 chr per file: had $wantedChr and also found $chr");
          }

          # Completion meta checks to see whether this track is already recorded
          # as complete for the chromosome, for this track
          if( $self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr) ) {
            $wantedChr = $chr;
          } else {
            $wantedChr = undef;
          }
        }

        # We expect either one chr per file, or all in one file
        # However, chr-split CADD files may have multiple chromosomes after liftover
        if(!$wantedChr) {
          # So we require sorted_guranteed flag for "last" optimization
          if($self->chrPerFile && $self->sorted_guaranteed) {
            last FH_LOOP;
          }
          next FH_LOOP;
        }

        # We log these because cadd has a number of "M" bases, at least on chr3 in 1.3
        if( ! $fields[$refBaseIdx] =~ /ACTGN/ ) {
          $self->log('warn', "Found non-ACTG reference, skipping line # $. : $line");
          next FH_LOOP;
        }

        my $dbPosition = $fields[1] - $based;

        if(!defined $count{$wantedChr}) { $count{$wantedChr} = 0; }

        ######## If we've changed position, we should have a 3 or 4 mer ########
        ####################### If so, write that ##############################
        if(defined $lastPosition && $lastPosition != $dbPosition) {
          if( !defined $scores{$wantedChr}{$lastPosition} ) {
            # Could occur if we skipped the lastPosition because refBase didn't match
            # assemblyRefBase
            $self->log('warn', "lastPosition $lastPosition not found in scores hash");
          } else {
            if(!defined $out{$wantedChr} ) { $out{$wantedChr} = {}; $count{$wantedChr} = 0; }

            my $success = $self->_accumulateScores( $scores{$wantedChr}{$lastPosition}, $out{$wantedChr} );

            # We accumulated a 3 or 4-mer
            # Note that we assume that after we accumulate one 3-4 mer, there won't
            # be an identical chr:position elsewhere in the file
            # Could test, but that would be memory intensive
            if($success) {
              $count{$wantedChr}++; delete $scores{$wantedChr}{$lastPosition};
            }
          }
        }

        if($count{$wantedChr} >= $self->commitEvery) {
          if( !%{ $out{$wantedChr} } ) {
            $self->log('fatal', "out{$wantedChr} empty but count >= commitEvery");
          }

          $self->db->dbPatchBulkArray( $wantedChr, $out{$wantedChr} );

          $count{$wantedChr} = 0; delete $out{$wantedChr};
        }

        ##### Build up the scores into 3-mer (or 4-mer if ambiguous base) #####

        # This site will be next in 1 iteration
        $lastPosition = $dbPosition;

        my $altAllele = $fields[$altAlleleIdx];
        my $refBase = $fields[$refBaseIdx];

        # WHY DOESN"T THIS WORK
        # if(! $dbPosition >= 0) {
        #   $self->log('fatal', "Found unreasonable position ($dbPosition) on line \#$.:$line");
        # }

        # Checks against CADD score corruption
        if(defined $scores{$wantedChr}{$dbPosition}{ref} ) {
          if($scores{$wantedChr}{$dbPosition}{ref} ne $refBase) {
            return $self->log('fatal', "Multiple reference bases in 3-mer @ line # $. : $line");
          }
        } else {
          $scores{$wantedChr}{$dbPosition}{ref} = $refBase;
        }

        if(!defined $fields[$phastIdx]) {
          return $self->log('fatal', "No phast score found on line \#$.:$line");
        }

        # Store the position to allow us to get our databases reference sequence
        # This is also used in _accumulateScores to set the $out position
        if(!defined $scores{$wantedChr}{$dbPosition}{pos}) {
          $scores{$wantedChr}{$dbPosition}{pos} = $dbPosition;
        }
        
        push @{ $scores{$wantedChr}{$dbPosition}{scores} }, [ $altAllele, $rounder->round( $fields[$phastIdx] ) ];

        ### Record that we visited the chr, to enable recordCompletion later ###
        if( !defined $visitedChrs{$wantedChr} ) { $visitedChrs{$wantedChr} = 1 };

        ########### Check refBase against the assembly's reference #############
        my $dbData = $self->db->dbRead( $wantedChr, $scores{$wantedChr}{$dbPosition}{pos} );
        my $assemblyRefBase = $refTrack->get($dbData);

        # When lifted over, reference base is not lifted, can cause mismatch
        # In these cases it makes no sense to store this position's CADD data
        if( $assemblyRefBase ne $scores{$wantedChr}{$dbPosition}{ref} ) {
          $self->log('warn', "Line \#$. CADD ref == $scores{$wantedChr}{$dbPosition}{ref},"
            . " while Assembly ref == $assemblyRefBase. Skipping: $line");
          
          # so that this won't be be used in the lastPosition != dbPosition check
          delete $scores{$wantedChr}{$dbPosition};

          next FH_LOOP;
        }
      }
      ######################### Finished reading file ##########################
      ######### Collect any scores that were accumulated out of order ##########
      for my $chr (keys %scores) {
        if( %{$scores{$chr} } ) {
          $self->log('info', "After reading $file, have " . (scalar keys %{ $scores{$chr} } )
            . " positions left to commit for $chr" );

          for my $position ( keys %{ $scores{$chr} } ) {
            # Using delete to force Perl to free memory
            if(!defined $out{$chr} ) { $out{$chr} = {}; $count{$chr} = 0; }

            my $success = $self->_accumulateScores( $scores{$chr}{$position}, $out{$chr} );
              
            # Can free up the memory now, won't use this $scores{$chr}{$pos} again
            delete $scores{$chr}{$position};

            if($success) { $count{$chr}++; }

            if( $count{$chr} >= $self->commitEvery ) {
              if( ! %{ $out{$chr} } ) {
                $self->log('fatal', "out{$chr} empty, but count >= commitEvery");
              }

              $self->db->dbPatchBulkArray( $chr, $out{$chr} );
              
              $count{$chr} = 0; delete $out{$chr};
            }
          }
        }
      }

      #leftovers
      OUT_LOOP: for my $chr (keys %out) {
        if( ! %{ $out{$chr} } ) { next OUT_LOOP; }

        $self->db->dbPatchBulkArray( $chr, $out{$chr} );
      }

      $self->log("info", "Finished building ". $self->name . " version: $versionLine using $file");

    $pm->finish(0, \%visitedChrs);
  }

  ######Record completion status only if the process completed unimpeded ########
  my %visitedChrs;
  $pm->run_on_finish(sub {
    my ($pid, $exitCode, $fileName, $exitSignal, $coreDump, $visitedChrsHref) = @_;
    
    if($exitCode != 0) {
      $self->log('fatal', "Failed to finish with $exitCode");
    }

    $self->log('info', "Got exit code $exitCode for $fileName");

    foreach (keys %$visitedChrsHref) {
      $visitedChrs{$_} = 1;
    }
  });

  $pm->wait_all_children;

  # Since any detected errors are fatal, we have confidence that anything visited
  # Is complete (we only have 1 file to read)
  foreach (keys %visitedChrs) {
    $self->completionMeta->recordCompletion($_);
  }
}

sub buildTrackFromHeaderlessWigFix {
  my $self = shift;
  $self->log('fatal', "Custom wigFix format no longer allowed."
    . " Please use either CADD format, or bed-like cadd format, which should have"
    . " 2 header lines, like in a regular CADD file, with the first being"
    . " the version / copyright, the 2nd being the tab-delimited names of columns."
    . " However, on this 2nd line, instead of #Chrom\tPos the bed-like format expects"
    . " chrom chromStart chromEnd as the first 3 column names (adding chromEnd)"
    , " and regular CADD field names after that.");
}

sub _accumulateScores {
  my ($self, $dataHref, $outHref) = @_;

  if(!defined $outHref || ref $outHref ne 'HASH') {
    $self->log('fatal', "outHref not defined or not a hash reference");
  }

  my $scoresAref = $dataHref->{scores};
          
  if(@$scoresAref != 3 && @$scoresAref != 4) {
    # We will try again at the end of the file
    return $self->log('warn', "pos $dataHref->{pos} doesn't have 3 or 4 scores");
  }

  my @phredScores;

  my $ref = $dataHref->{ref};

  for my $aref (@$scoresAref) {
    my $index = $order->{$ref}{$aref->[0] };

    # checks whether ref and alt allele are ACTG
    if(!defined $index) {
      return $self->log('fatal', "ref $ref or allele $aref->[0] not ACTGN");
    }

    $phredScores[$index] = $aref->[1];
  }

  # Check if the cadd 3-mer had non-unique alleles, or ANYTHING else went wrong
  foreach (@phredScores) {
    if(!defined $_) {
      return $self->log('fatal', "CADD 3 or 4-mer Phred score array was sparse");
    }
  }

  # Only ambiguous bases can have 4 cadd scores
  if($ref ne 'N' && @phredScores == 4) {
    $self->log('fatal', "Found CADD 4-mer for non-N base");
  }

  # If array copy needed: #https://ideone.com/m08q9V ; https://ideone.com/dZ6RGj
  $outHref->{ $dataHref->{pos} } = $self->prepareData( \@phredScores );

  # Return 1 if successfully added to $out
  return 1;
}
__PACKAGE__->meta->make_immutable;
1;
