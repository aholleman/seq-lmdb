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
############## Version that does not assume positions in order ################
sub buildTrack {
  my $self = shift;

  my $pm = Parallel::ForkManager->new($self->max_threads);
  
  my $columnDelimiter = $self->delimiter;

  my $mergeFunc = $self->_makeMergeFunc();

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
      my %skipSites;

      my $wantedChr;

      # Track which fields we recorded, to record in $self->completionMeta
      my %visitedChrs = ();

      # Cadd scores can be out of order after liftOver, which means
      # that we may write to the same database from multiple processes
      # This is done in a fork, so other instances of Seq::Tracks::*::BUILD not affected
      if(!$self->sorted_guaranteed && $self->commitEvery > 5e3) {
        # To reduce lock contention (maybe?), reduce database inflation mostly
        $self->commitEvery(5e3);
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

            $self->db->dbPatchBulkArray( $wantedChr, $out{$wantedChr}, undef, $mergeFunc);
            
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

        ### Record that we visited the chr, to enable recordCompletion later ###
        if( !defined $visitedChrs{$wantedChr} ) { $visitedChrs{$wantedChr} = 1 };

        # We log these because cadd has a number of "M" bases, at least on chr3 in 1.3
        if( ! $fields[$refBaseIdx] =~ /ACTG/ ) {
          $self->log('warn', "Found non-ACTG reference, skipping line # $. : $line");
          next FH_LOOP;
        }

        my $dbPosition = $fields[1] - $based;

        ######## If we've changed position, we should have a 3 mer ########
        ####################### If so, write that ##############################
        ####################### If not, wait until we do #######################
        if(defined $lastPosition && $lastPosition != $dbPosition) {
          if( defined $skipSites{"$wantedChr\_$lastPosition"} ) {
            $self->log('info', "Changed position. Skipping $wantedChr:$lastPosition"
              . " because: " . $skipSites{"$wantedChr\_$lastPosition"} );


            # Skipped sites may write undef for the position, because if multiple
            # 3-mers exist for this site (can occur during liftover), we want to avoid
            # allowing a cryptic N-mer
            # Writing an undef at the position will ensure that mergeFunc is called
            # because it is called when the database contains any defined entry for the
            # cadd track
            $out{$wantedChr}{$lastPosition} = $self->prepareData( [] );
            $count{$wantedChr}++;

            delete $scores{$wantedChr}{$lastPosition};
            delete $skipSites{"$wantedChr\_$lastPosition"};
          } elsif( !defined $scores{$wantedChr}{$lastPosition} ) {
            # Could occur if we skipped the lastPosition because refBase didn't match
            # assemblyRefBase
            $self->log('warn', "lastPosition $chr\=\>$lastPosition not found in CADD scores hash");
          } else {
            ########### Check refBase against the assembly's reference #############
            my $dbData = $self->db->dbRead( $wantedChr, $lastPosition );
            my $assemblyRefBase = $refTrack->get($dbData);

            if(!defined $assemblyRefBase) {
              say "for $wantedChr:$lastPosition couldn't find assembly ref base";

              $self->log('fatal', "No assembly ref base found for $wantedChr:$lastPosition");
            }
            # When lifted over, reference base is not lifted, can cause mismatch
            # In these cases it makes no sense to store this position's CADD data
            if($assemblyRefBase ne $scores{$wantedChr}{$lastPosition}{ref} ) {
              # $self->log('warn', "Inserting undef into $wantedChr:$lastPosition because CADD ref "
              #   . " == $scores{$wantedChr}{$lastPosition}{ref}, assembly ref == $assemblyRefBase\.");
              
              # In case there are multiple 3-mers in the file with the same chr-pos
              # store an undef at this $lastPosition, to allow triggering of mergeFunc
              $out{$wantedChr}{$lastPosition} = $self->prepareData( [] );
              $count{$wantedChr}++;

              delete $scores{$wantedChr}{$lastPosition};
            } else {
              my $phredScoresAref = $self->_accumulateScores( $wantedChr, $scores{$wantedChr}{$lastPosition} );

               # We accumulated a 3-mer
               # Note that we assume that after we accumulate one 3 mer, there won't
               # be an identical chr:position elsewhere in the file
               # Could test, but that would be memory intensive
              if(defined $phredScoresAref) {
                if(!defined $out{$wantedChr} ) { $out{$wantedChr} = {}; $count{$wantedChr} = 0; }

                $out{$wantedChr}{$lastPosition} = $self->prepareData( $phredScoresAref );
                
                $count{$wantedChr}++;

                #Only delete if we got our phredScores 3-mer, else leave until
                #end of file
                delete $scores{$wantedChr}{$lastPosition};
              }

              # If we don't have enough scores yet, it's possible the pos is out 
              # of order; If so, we want to catch it on a later run, therefore
              # don't delete $scores{$wantedChr}{$lastPosition}
              # multiple 3-mers per chr:pos will also be caught (by the merge func)
              # Non-3 multiples will currently pose an issue 
            }
          }
        }

        if(!defined $out{$wantedChr} ) { $out{$wantedChr} = {}; $count{$wantedChr} = 0; }
        
        if($count{$wantedChr} >= $self->commitEvery) {
          if( !%{ $out{$wantedChr} } ) {
            $self->log('fatal', "out{$wantedChr} empty but count >= commitEvery");
          }

          $self->db->dbPatchBulkArray( $wantedChr, $out{$wantedChr}, undef, $mergeFunc);

          $count{$wantedChr} = 0; delete $out{$wantedChr};
        }

        ##### Build up the scores into 3-mer (or 4-mer if ambiguous base) #####

        # This site will be next in 1 iteration
        $lastPosition = $dbPosition;

        if( defined $skipSites{"$wantedChr\_$dbPosition"} ) {
          next;
        }

        my $altAllele = $fields[$altAlleleIdx];
        my $refBase = $fields[$refBaseIdx];

        # WHY DOESN"T THIS WORK
        # if(! $dbPosition >= 0) {
        #   $self->log('fatal', "Found unreasonable position ($dbPosition) on line \#$.:$line");
        # }

        # Checks against CADD score corruption
        if(defined $scores{$wantedChr}{$dbPosition}{ref} ) {
          # If we find a position that has multiple bases, that is undefined behavior
          # so we will store a nil (undef on perl side, nil in msgpack) for cadd at that position
          if($scores{$wantedChr}{$dbPosition}{ref} ne $refBase) {
            $self->log('warn', "Multiple reference bases in 3-mer @ $wantedChr:$dbPosition,"
              . "  excluding this position. Line # $. : $line");
            
            # Mark for undef insertion
            $skipSites{"$wantedChr\_$dbPosition"} = "Multi-ref";

            next;
          }
        } else {
          $scores{$wantedChr}{$dbPosition}{ref} = $refBase;
        }

        # If no phastIdx found for this site, there cannot be 3 scores accumulated
        # so write a nil
        if(!defined $fields[$phastIdx]) {
          $self->log('warn', "No phast score found for $wantedChr:$dbPosition,"
            ." excluding this position. Line \#$.:$line");
          
          # Mark for undef insertion
          $skipSites{"$wantedChr\_$dbPosition"} = "Missing-score";

          next;
        }

        # Store the position to allow us to get our databases reference sequence
        # This is also used in _accumulateScores to set the $out position
        if(!defined $scores{$wantedChr}{$dbPosition}{pos}) {
          $scores{$wantedChr}{$dbPosition}{pos} = $dbPosition;
        }
        
        push @{ $scores{$wantedChr}{$dbPosition}{scores} }, [ $altAllele, $rounder->round( $fields[$phastIdx] ) ];
      }
      ######################### Finished reading file ##########################
      ######### Collect any scores that were accumulated out of order ##########
      for my $chr (keys %scores) {
        if( %{$scores{$chr} } ) {
          $self->log('debug', "After reading $file, have " . (scalar keys %{ $scores{$chr} } )
            . " positions left to commit for $chr, at positions " . join(',', keys %{ $scores{$chr} } ) );

          for my $position ( keys %{ $scores{$chr} } ) {
            if ( defined $skipSites{"$chr\_$position"} ) {
              $self->log('info', "At end, inserting undef at $chr:$position because: " . $skipSites{"$chr\_$position"} );
             
              # Skipped sites may write undef for the position, because if multiple
              # 3-mers exist for this site (can occur during liftover), we want to avoid
              # allowing a cryptic N-mer
              # Writing an undef at the position will ensure that mergeFunc is called
              # because it is called when the database contains any entry for the
              # cadd track, undef included
              $out{$chr}{$position} = $self->prepareData( [] );
              $count{$chr}++;

              delete $skipSites{"$chr\_$position"};
            } else {
              my $dbData = $self->db->dbRead( $chr, $position );
              my $assemblyRefBase = $refTrack->get($dbData);

              if( $assemblyRefBase ne $scores{$chr}{$position}{ref} ) {
                $self->log('warn', "After reading $file, at $chr\:$position, "
                  . " CADD ref == $scores{$chr}{$position}{ref},"
                  . " while Assembly ref == $assemblyRefBase. Excluding this position.");
                
                # If don't have correct ref, still insert undef,
                # to prevent allowance of odd cryptic N-mers (N > 3)
                $out{$chr}{$position} = $self->prepareData( [] );
              } else {
                # Using delete to encourage Perl to free memory
                if(!defined $out{$chr} ) { $out{$chr} = {}; $count{$chr} = 0; }

                my $phredScoresAref = $self->_accumulateScores( $chr, $scores{$chr}{$position} );
                  
                # If don't have a phred score 3-mer, still insert empty array,
                # to prevent allowance of odd cryptic N-mers (N > 3)
                if(!defined $phredScoresAref) {
                  $phredScoresAref = [];
                }

                $out{$chr}{$position} = $self->prepareData( $phredScoresAref );
              }

              $count{$chr}++;
            }

            if( $count{$chr} >= $self->commitEvery ) {
              if( ! %{ $out{$chr} } ) {
                $self->log('fatal', "out{$chr} empty, but count >= commitEvery");
              }

              $self->db->dbPatchBulkArray( $chr, $out{$chr}, undef, $mergeFunc);
              
              $count{$chr} = 0; delete $out{$chr};
            }

            # Can free up the memory now, won't use this $scores{$chr}{$pos} again
            delete $scores{$chr}{$position};
          }
        }
      }

      #leftovers
      OUT_LOOP: for my $chr (keys %out) {
        if( ! %{ $out{$chr} } ) { next OUT_LOOP; }

        $self->db->dbPatchBulkArray( $chr, $out{$chr}, undef, $mergeFunc);
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

sub _accumulateScores {
  #my ($self, $chr, $data) = @_;
  #    $_[0] , $_[1], $_[2]
  if(@{ $_[2]->{scores} } != 3) {
    # We will try again at the end of the file
    $_[0]->log('warn', "pos $_[2]->{pos} doesn't have 3 scores, skipping");
    return;
  }

  my @phredScores;

  for my $aref ( @{ $_[2]->{scores} } ) {
    my $index = $order->{ $_[2]->{ref} }{$aref->[0] };

    # checks whether ref and alt allele are ACTG
    if(!defined $index) {
      return $_[0]->log('warn', "ref $_[2]->{ref} or allele $aref->[0] not ACTGN, skipping");
    }

    $phredScores[$index] = $aref->[1];
  }

  if(@phredScores != 3) {
    return $_[0]->log('warn', "Found non-unique alt alleles for $_[2]->{pos}, skipping");
  }

  return \@phredScores;
}

# When CADD scores are put through liftover, may be out of order
# This means that it is possible for two positions, from different chromosomes
# to have been lifted over to the same chr:pos
# In this case, the CADD data is indeterminate.
# However, it makes more sense I think to have mergeFunc run only on defined data
# and "undefined" has two meanings: not there, and data that was purposely set to nil
sub _makeMergeFunc {
  my $self = shift;

  return sub {
    # This function is called only for existing oldTrackVals
    # And in any case that an existing value is found, the new value is nil
    my ($chr, $pos, $trackIdx, $oldTrackVal, $newTrackVal) = @_;
    
    $self->log("in CADD merge function, found an existing value @ $chr:$pos ".
               ". Setting $chr:$pos to undef/nil");

    return [];
  }
}

########## Working on version that assumes in-order, in case memory pressure above too much ####
# sub buildTrack {
#   my $self = shift;

#   my $pm = Parallel::ForkManager->new(scalar @{$self->local_files});
  
#   my $columnDelimiter = $self->delimiter;

#   for my $file ( @{$self->local_files} ) {
#     $pm->start($file) and next;

#       my $fh = $self->get_read_fh($file);

#       my $versionLine = <$fh>;
#       chomp $versionLine;
      
#       if( index($versionLine, '## CADD') == - 1) {
#         $self->log('fatal', "First line of CADD file is not CADD formatted: $_");
#       }

#       $self->log("info", "Building ". $self->name . " version: $versionLine using $file");

#       # Cadd's columns descriptor is on the 2nd line
#       my $headerLine = <$fh>;
#       chomp $headerLine;

#       # We may have converted the CADD file to a BED-like format, which has
#       # chrom chromStart chromEnd instead of #Chrom Pos
#       # and which is 0-based instead of 1 based
#       # Moving $phastIdx to the last column
#       my @headerFields = split $columnDelimiter, $headerLine;

#       # Get the last index, that's where the phast column lives https://ideone.com/zgtKuf
#       # Can be 5th or 6th column idx. 5th for CADD file, 6th for BED-like file
#       my $phastIdx = $#headerFields;

#       my $altAlleleIdx = $#headerFields - 2;
#       my $refBaseIdx = $#headerFields - 3;

#       my $based = $self->based;
#       my $isBed;
      
#       if(@headerFields == 7) {
#         # It's the bed-like format
#         $based = 0;
#         $isBed = 1;
#       }

#       # Accumulate 3 lines worth of PHRED scores
#       # We cannot assume the CADD file will be properly sorted when liftOver used
#       # So checks need to be made
#       my %scores;

#       my %out;
#       my $count = 0;
#       my $wantedChr;

#       # Track which fields we recorded, to record in $self->completionMeta
#       my %visitedChrs = ();

#       # Cadd scores can be out of order after liftOver, which means
#       # that we may write to the same database from multiple processes
#       if(!$self->sorted_guaranteed) {
#         # To reduce lock contention (maybe?), reduce database inflation mostly
#         $self->commitEvery(1000);
#       }
      
#       my $lastPos;

#       # File does not need to be sorted by chromosome, but each position
#       # must be in a block of 3 (one for each possible allele)
#       FH_LOOP: while ( my $line = $fh->getline() ) {
#         chomp $line;
        
#         my @fields = split $columnDelimiter, $line;

#         my $chr = $isBed ? $fields[0] : "chr$fields[0]";

#         if( !$wantedChr || ($wantedChr && $wantedChr ne $chr) ) {
#           if(%out) {
#             if(!$wantedChr) { $self->log('fatal', "Changed chr @ line $., but no wantedChr");}
            
#             $self->db->dbPatchBulkArray($wantedChr, \%out);
#             undef %out; $count = 0;
#           }

#           if( %scores ) {
#             return $self->log('fatal', "Changed chr @ line # $. with un-saved scores");
#           }

#           if($wantedChr && $self->chrPerFile) {
#             $self->log('warn', "Expected 1 chr per file: had $wantedChr and also found $chr");
#           }

#           # Completion meta checks to see whether this track is already recorded
#           # as complete for the chromosome, for this track
#           if( $self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr) ) {
#             $wantedChr = $chr;
#           } else {
#             $wantedChr = undef;
#           }
#         }

#         # We expect either one chr per file, or all in one file
#         # However, chr-split CADD files may have multiple chromosomes after liftover
#         if(!$wantedChr) {
#           # So we require override 
#           if($self->chrPerFile && $self->sorted_guaranteed) {
#             last FH_LOOP;
#           }
#           next FH_LOOP;
#         }

#         my $dbPosition = $fields[1] - $based;
#         my $refBase = $fields[$refBaseIdx];

#         # We've changed position
#         if(defined $lastPos && $lastPos != $dbPosition) {
#           my $dbData = $self->db->dbRead($wantedChr, $scores{pos} );
#           my $assemblyRefBase = $refTrack->get($dbData);

#           # When lifted over, reference base is not lifted, can cause mismatch
#           # In these cases it makes no sense to store this position's CADD data
#           if( $assemblyRefBase ne $scores{ref} ) {
#             $self->log('warn', "Line \#$. assembly ref == $scores{ref}, CADD == $assemblyRefBase. Skipping.");
            
#             undef %scores;

#             next;
#           }

#           my @phastScores;

#           for my $aref (@{$scores{scores} } ) {
#             my $index = $order->{$scores{ref} }{$aref->[0] };

#             # checks whether ref and alt allele are ACTG
#             if(!defined $index) {
#               $self->log('fatal', "ref $aref->[0] or allele $aref->[1] not ACTGN");
#             }

#             $phastScores[$index] = $aref->[1];
#           }

#           # Check if the cadd 3-mer had non-unique alleles, or ANYTHING else went wrong
#           foreach (@phastScores) {
#             if(!defined $_) {
#               $self->log('fatal', "Found less than 3 unique alleles in CADD 3-mer");
#             }
#           }

#           if(@phastScores != 3 && @phastScores !=4) {
#             $self->log('fatal', "Accumulated less than 3 or 4-mer CADD score array");
#           }

#           # If array copy needed: #https://ideone.com/m08q9V ; https://ideone.com/dZ6RGj
#           $out{$scores{pos} } = $self->prepareData( \@phastScores );
            
#           undef %scores;

#           if($count >= $self->commitEvery) {
#             $self->db->dbPatchBulkArray($wantedChr, \%out);

#             undef %out;
#             $count = 0;
#           }

#           $count++;
#         }

#         if( ! $fields[$refBaseIdx] =~ /ACTGN/ ) {
#           $self->log('warn', "Found non-ACTG reference, skipping line # $. : $line");
#           next FH_LOOP;
#         }

#         my $altAllele = $fields[$altAlleleIdx];
        

#         # WHY DOESN"T THIS WORK
#         # if(! $dbPosition >= 0) {
#         #   $self->log('fatal', "Found unreasonable position ($dbPosition) on line \#$.:$line");
#         # }

#         $lastPos = $dbPosition;

#         # Specify 2 significant figures by default
#         if(defined $scores{ref} ) {
#           if($scores{ref} ne $refBase) {
#             return $self->log('fatal', "Multiple reference bases in 3-mer @ line # $. : $line");
#           }
#         } else {
#           $scores{ref} = $refBase;
#         }

#         if(defined $scores{pos} ) {
#           if($scores{pos} != $dbPosition) {
#             return $self->log('fatal', "3mer out of order @ line # $. : $line");
#           }
#         } else {
#           $scores{pos} = $dbPosition;
#         }

#         if(!defined $fields[$phastIdx]) {
#           return $self->log('fatal', "No phast score found on line \#$.:$line");
#         }

#         push @{$scores{scores} }, [$altAllele, $rounder->round($fields[$phastIdx] ) ];

#         # Count 3-mer scores recorded for commitEvery, & chromosomes seen for completion recording
#         if(!defined $visitedChrs{$chr} ) { $visitedChrs{$chr} = 1 };
#       }

#       # leftovers
#       if(%out) {
#         if(!$wantedChr) { $self->log('fatal', "Have out but no wantedChr"); }
#         if( %scores ) { 
#           $self->log('warn', "At end of $file have uncommited scores for position $scores{pos}");
#         }

#         $self->db->dbPatchBulkArray($wantedChr, \%out);
#       }

#     $pm->finish(0, \%visitedChrs);
#   }

#   my %visitedChrs;
#   $pm->run_on_finish(sub {
#     my ($pid, $exitCode, $fileName, $exitSignal, $coreDump, $visitedChrsHref) = @_;
    
#     if($exitCode != 0) {
#       $self->log('fatal', "Failed to finish with $exitCode");
#     }

#     $self->log('info', "Got exit code $exitCode for $fileName");

#     foreach (keys %$visitedChrsHref) {
#       $visitedChrs{$_} = 1;
#     }
#   });

#   $pm->wait_all_children;

#   # Since any detected errors are fatal, we have confidence that anything visited
#   # Is complete (we only have 1 file to read)
#   foreach (keys %visitedChrs) {
#     $self->completionMeta->recordCompletion($_);
#   }
# }
__PACKAGE__->meta->make_immutable;
1;
