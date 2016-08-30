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
############## Will optimize for cases when sorted_guranteed truthy ###########
sub buildTrack {
  my $self = shift;

  my $pm = Parallel::ForkManager->new($self->max_threads);
  
  my $columnDelimiter = $self->delimiter;

  my $mergeFunc;
  my $missingValue;

  # save accessor time
  my $sortedGuaranteed = $self->sorted_guaranteed;

  # If we cannot rely on the cadd sorting order, we must use a defined
  # value for those bases that we skip, because we'll ned mergeFunc
  # to know when data was found for a position, and when it is truly missing
  # Because when CADD scores are not sorted, each chromosome-containing file
  # can potentially have any other chromosome's scores, meaning we may get 
  # 6-mers or greater for a single position; when that happens the only
  # sensible solution is to store a missing value; undef would be nice, 
  # but that will never get triggered, unless our database is configured to store
  # hashes instead of arrays; since a sparse array will contain undef/nil 
  # for any track at that position that has not yet been inserted into the db
  if(!$sortedGuaranteed) {
    $missingValue = [];
    $mergeFunc = $self->_makeMergeFunc($missingValue);
  }

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

            if($self->sorted_guaranteed) {
              return $self->log('fatal', "Changed chromosomes, but expected sorted by chr");
            }

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
          if($self->chrPerFile && $sortedGuaranteed) {
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
            $out{$wantedChr}{$lastPosition} = $self->prepareData( $missingValue );
            $count{$wantedChr}++;

            # it's safe to delete this, because 
            delete $scores{$wantedChr}{$lastPosition};

            # if sorting is not guaranteed, its possible we'll see this combo again
            # by storing this we'll reduce the number of times we need to rely
            # on merging operations to handle bad sites
            if($sortedGuaranteed) {
              delete $skipSites{"$wantedChr\_$lastPosition"};
            }
            
          } elsif( !defined $scores{$wantedChr}{$lastPosition} ) {
            # Could occur if we skipped the lastPosition because refBase didn't match
            # assemblyRefBase
            $self->log('warn', "lastPosition $chr\:$lastPosition not found in CADD scores hash");
          } else {
            ########### Check refBase against the assembly's reference #############
            my $dbData = $self->db->dbReadOne( $wantedChr, $lastPosition );
            my $assemblyRefBase = $refTrack->get($dbData);

            if(!defined $assemblyRefBase) {
              say "for $wantedChr:$lastPosition couldn't find assembly ref base";
              say "the data is";
              p $dbData;
              
              $self->log('fatal', "No assembly ref base found for $wantedChr:$lastPosition");
            }

            # When lifted over, reference base is not lifted, can cause mismatch
            # In these cases it makes no sense to store this position's CADD data
            if($assemblyRefBase ne $scores{$wantedChr}{$lastPosition}{ref} ) {
              # $self->log('warn', "Inserting undef into $wantedChr:$lastPosition because CADD ref "
              #   . " == $scores{$wantedChr}{$lastPosition}{ref}, assembly ref == $assemblyRefBase\.");
              
              # In case there are multiple 3-mers in the file with the same chr-pos
              # store an undef at this $lastPosition, to allow triggering of mergeFunc
              $out{$wantedChr}{$lastPosition} = $self->prepareData( $missingValue );
              $count{$wantedChr}++;

              delete $scores{$wantedChr}{$lastPosition};
            } else {
              my $phredScoresAref = $self->_accumulateScores( $wantedChr, $scores{$wantedChr}{$lastPosition} );

               # We either accumulated a 3-mer, or something else
               # If sorting is guaranteed, we know for a fact we will never come
               # back to this position, so we can write the missingValue
              if(defined $phredScoresAref || $sortedGuaranteed) {
                if(!defined $out{$wantedChr} ) { $out{$wantedChr} = {}; $count{$wantedChr} = 0; }

                # $missingValue will only be inserted when !defined phredScoresAref
                # && $sortedGuaranteed
                $out{$wantedChr}{$lastPosition} = $self->prepareData( $phredScoresAref || $missingValue );
                
                $count{$wantedChr}++;

                #Only delete if we got our phredScores 3-mer, else leave until
                #end of file
                delete $scores{$wantedChr}{$lastPosition};
              }

              # If we don't have enough scores yet, and sorting not guaranteed
              # it's possible the pos is out  of order; If so, we want to
              # catch it on a later run, therefore
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
            # Mark for $missingValue insertion
            $skipSites{"$wantedChr\_$dbPosition"} = "Multi-ref";

            next;
          }
        } else {
          $scores{$wantedChr}{$dbPosition}{ref} = $refBase;
        }

        # If no phastIdx found for this site, there cannot be 3 scores accumulated
        # so mark it as for skipping; important because when out of order
        # we may have cryptic 3-mers, which we don't want to insert
        if(!defined $fields[$phastIdx]) {
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
              $out{$chr}{$position} = $self->prepareData( $missingValue );
              $count{$chr}++;

              # always safe to delete here; last time we'll check it
              delete $skipSites{"$chr\_$position"};
            } else {
              my $dbData = $self->db->dbReadOne( $chr, $position );
              my $assemblyRefBase = $refTrack->get($dbData);

              if( $assemblyRefBase ne $scores{$chr}{$position}{ref} ) {
                $self->log('warn', "After reading $file, at $chr\:$position, "
                  . " CADD ref == $scores{$chr}{$position}{ref},"
                  . " while Assembly ref == $assemblyRefBase. Excluding this position.");
                
                # If don't have correct ref, still insert undef,
                # to prevent allowance of odd cryptic N-mers (N > 3)
                $out{$chr}{$position} = $self->prepareData( $missingValue );
              } else {
                # Using delete to encourage Perl to free memory
                if(!defined $out{$chr} ) { $out{$chr} = {}; $count{$chr} = 0; }

                my $phredScoresAref = $self->_accumulateScores( $chr, $scores{$chr}{$position} );
                
                # We want to keep missing values consistent
                # Because when sorting not guaranteed, we may want non-nil/undef 
                # values to prevent cryptic 3-mers
                $out{$chr}{$position} = $self->prepareData( $phredScoresAref || $missingValue);
              }

              $count{$chr}++;
            }

            if( $count{$chr} >= $self->commitEvery ) {
              if( ! %{ $out{$chr} } ) {
                $self->log('fatal', "out{$chr} empty, but count >= commitEvery");
              }

              $self->db->dbPatchBulkArray( $chr, $out{$chr}, undef, $mergeFunc);
              
              # be aggressive in freeing memory
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
    # $_[0]->log('warn', "pos $_[2]->{pos} doesn't have 3 scores, skipping");
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
  my $missingValue = shift;

  return sub {
    # This function is called only for existing oldTrackVals
    # And in any case that an existing value is found, the new value is nil
    #my ($chr, $pos, $trackIdx, $oldTrackVal, $newTrackVal) = @_;
    #   $_[0], $_[1]
    $self->log("CADD merge function found existing value @ $_[0]:$_[1]. Setting to missingValue");

    return $missingValue;
  }
}

__PACKAGE__->meta->make_immutable;
1;
