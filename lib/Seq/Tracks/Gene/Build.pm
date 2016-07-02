use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Build;

our $VERSION = '0.001';

# ABSTRACT: Builds Gene Tracks 
    # Takes care of gene_db, transcript_db, and ngene from the previous Seqant version

    #Inserts a single value <ArrayRef> @ $self->name
    #If $self->nearest defined, inserts a <Int> @ $self->nearestFeatureName


use Moose 2;
use namespace::autoclean;

use Parallel::ForkManager;

use Seq::Tracks::Gene::Build::TX;

extends 'Seq::Tracks::Build';

#exports regionTrackPath
with 'Seq::Tracks::Region::RegionTrackPath',
#exports allUCSCgeneFeatures
'Seq::Tracks::Gene::Definition';

use DDP;

# Unlike original GeneTrack, we don't remap field names
# It's easier to remember the real names than real names + our domain-specific names

#can be overwritten if needed in the config file, as described in Tracks::Build
has chrom_field_name => (is => 'ro', lazy => 1, default => 'chrom' );
has txStart_field_name => (is => 'ro', lazy => 1, default => 'txStart' );
has txEnd_field_name => (is => 'ro', lazy => 1, default => 'txEnd' );

# These are the features stored in the Gene track's region database
# Provide default in case user doesn't specify any
has '+features' => (
  default => sub{ my $self = shift; return $self->allUCSCgeneFeatures; },
);

sub BUILD {
  my $self = shift;

  # geneTxErrorName isn't a default feature, initializing here to make sure 
  # we store this value (if calling for first time) before any threads get to it
  $self->getFieldDbName($self->geneTxErrorName);
}

# 1) Store a reference to the corresponding entry in the gene database (region database)
# 2) Store this codon information at some key, which the Tracks::Region::Gene
# 3) Store transcript errors, if any
# 4) Write region data
# 5) Write gene track data in main db
# 6) Write nearest genes if user wants those
sub buildTrack {
  my $self = shift;

  my $chrPerFile = scalar $self->allLocalFiles > 1 ? 1 : 0;

  my @allFiles = $self->allLocalFiles;

  my $pm = Parallel::ForkManager->new(scalar @allFiles);
  
  # Assume one file per loop, or all sites in one file. Tracks::Build warns if not
  for my $file (@allFiles) {
    $pm->start($file) and next;
      my %allIdx; # a map <Hash> { featureName => columnIndexInFile}
      my %regionIdx; #like allIdx, but only for features going into the region databae

      my $fh = $self->get_read_fh($file);

      my $firstLine = <$fh>;
      chomp $firstLine;
   
      # Store all features we can find, for Seq::Build::Gene::TX. Avoid autocracy,
      # don't need to know what Gene::TX requires.
      my $fieldIdx = 0;
      for my $field (split "\t", $firstLine) {
        $allIdx{$field} = $fieldIdx;
        $fieldIdx++;
      }

      # Except w.r.t the chromosome field, definitely need this
      if( !defined $allIdx{$self->chrom_field_name} ) {
        $self->log('fatal', 'must provide chromosome field');
      }

      # Region database features; as defined by user in the YAML config, or our default
      REGION_FEATS: for my $field ($self->allFeatureNames) {
        if(exists $allIdx{$field} ) {
          $regionIdx{$field} = $allIdx{$field};
          next REGION_FEATS;
        }

        $self->log('fatal', 'Required $field missing in $file header');
      }

      # Every row (besides header) describes a transcript
      my %allData;
      my %regionData;
      my %txStartData;

      my $wantedChr;
      my %txNumbers;

      FH_LOOP: while (<$fh>) {
        chomp;
        my @fields = split("\t", $_);

        my $chr = $fields[ $allIdx{$self->chrom_field_name} ];

        # We may have already finished this chr, or may not have asked for it
        if( !$self->completionMeta->okToBuild($chr) ) {
          $self->log('info', "Have already built $chr for " . $self->name);
          $wantedChr = undef;
        } elsif( ($wantedChr && $wantedChr ne $chr) || !$wantedChr ) {
          $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
        }
        
        if(!$wantedChr) {
          # if not wanted, and we have one chr per file, exit
          if($chrPerFile) {
            $self->log('info', "$chr not wanted, and 1 chr per file, skipping $file");
            last FH_LOOP;
          }

          #not wanted, but multiple chr per file, skip
          next FH_LOOP;
        }
        
        # Keep track of our 0-indexed transcript refreence numbers
        if( !$txNumbers{$wantedChr} ) {
          $txNumbers{$wantedChr} = 0;
        }

        my $txNumber = $txNumbers{$wantedChr};

        my $allDataHref;
        ACCUM_VALUES: for my $fieldName (keys %allIdx) {
          $allDataHref->{$fieldName} = $fields[ $allIdx{$fieldName} ];
            
          if(!defined $regionIdx{$fieldName} ) {
            next ACCUM_VALUES;
          }

          # if this is a field that we need to store in the region db
          # create a shortened field name
          my $fieldDbName = $self->getFieldDbName($fieldName);
          
          #store under a shortened fieldName to save space in the db
          $regionData{$wantedChr}->{$txNumber}{ $fieldDbName } = $allDataHref->{$fieldName};
        }

        my $txStart = $allDataHref->{$self->txStart_field_name};
        
        if(!$txStart) {
          $self->log('fatal', 'Missing transcript start ( we expected a value @ ' .
            $self->txStart_field_name . ')');
        }

        my $txEnd = $allDataHref->{$self->txEnd_field_name};
        
        if(!$txEnd) {
          $self->log('fatal', 'Missing transcript start ( we expected a value @ ' .
            $self->txEnd_field_name . ')');
        }

        if(defined $txStartData{$wantedChr}{$txStart} ) {
          push @{ $txStartData{$wantedChr}{$txStart} }, [$txNumber, $txEnd];
        } else {
          $txStartData{$wantedChr}{$txStart} = [ [$txNumber, $txEnd] ];
        }

        $allDataHref->{txNumber} = $txNumber;

        push @{ $allData{$wantedChr}{$txStart} }, $allDataHref;

        $txNumbers{$wantedChr} += 1;
      }
    
      if(!%allData) {
        #we skipped this chromosome worth of data
        $pm->finish(0);
      }

      ############################### Make transcripts #########################
      my @allChrs = keys %allData;

      my $pm2 = Parallel::ForkManager->new(scalar @allChrs);

      my $txErrorDbname = $self->getFieldDbName($self->geneTxErrorName);

      for my $chr (@allChrs) {
        $pm2->start($chr) and next;
          
          my (%siteData, %sitesCoveredByTX);

          $self->log('info', "Starting to build transcript for $file");

          my @allTxStartsAscending = sort { $a <=> $b } keys %{ $allData{$chr} };

          # To save space, we need to write the mainDb data early
          my $largestTxEnd = 0;
          for my $txStart ( @allTxStartsAscending ) {
            if($largestTxEnd < $txStart && %siteData) {
              $self->log('info', "largestTxEnd is $largestTxEnd and txStart is $txStart."
               . " Can't overlap, so writing accumulated siteData");
              # After we;ve moved past the last covered transcript, no risk of missing an overlap,
              # assuming all txStart > txEnd, which is the case according to
              # http://www.noncode.org/cgi-bin/hgTables?db=hg19&hgta_group=genes&hgta_track=refGene&hgta_table=refGene&hgta_doSchema=describe+table+schema
              $self->_writeMainData($chr, \%siteData);
              undef %siteData;
            }

            for my $txData ( @{ $allData{$chr}->{$txStart} } ) {
              my $txNumber = $txData->{txNumber};

              $self->log('info', "Starting to make transcript \#$txNumber for $chr");

              my $txInfo = Seq::Tracks::Gene::Build::TX->new($txData);

              # Store the data # To save space, both memory and later db, store as scalar if possible
              # uses 1/3rd the bytes in the container: http://perlmaven.com/how-much-memory-do-perl-variables-use
              INNER: for my $pos ( keys %{$txInfo->transcriptSites} ) {
                if(!defined $siteData{$pos} ) {
                  $siteData{$pos} = $txInfo->transcriptSites->{$pos};
                } else {
                  # make it an array
                  if(! ref $siteData{$pos}->[0] ) { $siteData{$pos} = [ $siteData{$pos} ]; }
                  # push it!
                  push @{ $siteData{$pos} }, $txInfo->transcriptSites->{$pos};
                }
                
                $sitesCoveredByTX{$pos} = 1;
              }

              if( @{$txInfo->transcriptErrors} ) {
                $regionData{$chr}->{$txNumber}{$txErrorDbname} = $txInfo->transcriptErrors;
              }

              if($txData->{txEnd} > $largestTxEnd) {
                $largestTxEnd = $txData->{txEnd};
              }

              $self->log('info', "Finished making transcript \#$txNumber for $chr");
            }
          }

          $self->log('info', "Finished building transcripts for $file");
          
          $self->_writeRegionData( $chr, $regionData{$chr} );

          if(%siteData) {
            $self->_writeMainData( $chr, \%siteData );
            undef %siteData;
          }

          if(!$self->noNearestFeatures) {
            $self->_writeNearestGenes( $chr, $txStartData{$chr}, \%sitesCoveredByTX );
          }

          undef %sitesCoveredByTX; 

          # We've finished with 1 chromosome, so write that to meta to disk
          $self->completionMeta->recordCompletion($chr);

        $pm2->finish(0);

        # Can only delete these outside the fork
        delete $allData{$chr}; delete $regionData{$chr}; delete $txStartData{$chr}; 
      }

      # Check exit codes for succses; 0 indicates success
      $pm2->run_on_finish( sub {
        my ($pid, $exitCode, $chr) = @_;
        if(!defined $exitCode || $exitCode != 0) {
          # Exit early, meaning parent doesn't $pm->finish(0), to reduce corruption
          $self->log('fatal', "Failed to build transcripts for $chr");
        }
      });

      $pm2->wait_all_children;

    $pm->finish(0);
  }

  # Done with all chromosomes. Tell caller whether we exited due to failure
  my @failed;
  $pm->run_on_finish( sub {
    my ($pid, $exitCode, $fileName) = @_;

    $self->log('debug', "Got exitCode $exitCode for $fileName");

    if($exitCode != 0) { push @failed, "Got exitCode $exitCode for $fileName"; }
  });

  $pm->wait_all_children;

  return @failed == 0 ? 0 : (\@failed, 255);
}

sub _writeRegionData {
  my ($self, $chr, $regionDataHref) = @_;

  $self->log('info', "Starting _writeRegionData for $chr");
    
  my $dbName = $self->regionTrackPath($chr);

  my @txNumbers = keys %$regionDataHref;

  my %out;
  my $count = 0;

  for my $txNumber (@txNumbers) {
    if($count >= $self->commitEvery) {
      # We put instead of patch, because we don't store the data identified by
      # its track dbName
      $self->dbPutBulk($dbName, \%out);

      undef %out;
      $count = 0;
    }

    #Only region tracks store their data directly, anything going into the
    #main database needs to prepare the data first (store at it's dbName)
    $out{$txNumber} = $regionDataHref->{$txNumber};
    
    $count += 1;
  }

  if(%out) {
    $self->dbPutBulk($dbName, \%out);

    undef %out;
  }

  $self->log('info', "Finished _writeRegionData for $chr");
}

sub _writeMainData {
  my ($self, $chr, $mainDataHref) = @_;

  $self->log('info', "Starting _writeMainData for $chr");
  
  my %out;
  my $count = 0;

  for my $pos ( keys %$mainDataHref ) {
    if($count >= $self->commitEvery) {
      $self->dbPatchBulkArray($chr, \%out);

      undef %out;
      $count = 0;
    }

    $out{$pos} = $self->prepareData( $mainDataHref->{$pos} );

    $count += 1;
  }

  if(%out) {
    $self->dbPatchBulkArray($chr, \%out);

    undef %out;
  }
    
  $self->log('info', "Finished _writeMainData for $chr");
}

# Find all of the nearest genes, for any intergenic regions
# Genic regions by our definition are nearest to themselves
# All UCSC refGene data is 0-based
# http://www.noncode.org/cgi-bin/hgTables?db=hg19&hgta_group=genes&hgta_track=refGene&hgta_table=refGene&hgta_doSchema=describe+table+schema
sub _writeNearestGenes {
  my ($self, $chr, $txStartData, $coveredSitesHref) = @_;
  
  $self->log('info', "Starting _writeNearestGenes for $chr");      
  
  # Get database length : assumes reference track already in the db
  my $genomeNumberOfEntries = $self->dbGetNumberOfEntries($chr);

  my @allTranscriptStarts = sort { $a <=> $b } keys %$txStartData;

  # Track the longest (further in db toward end of genome) txEnd, because
  #  in  case of overlapping transcripts, want the points that ARENT 
  #  covered by a gene (since those have apriori nearest records: themselves)
  #  This also acts as our starting position
  my $longestPreviousTxEnd = 0;
  my $longestPreviousTxNumber;

  TXSTART_LOOP: for (my $n = 0; $n < @allTranscriptStarts; $n++) {
    my $txStart = $allTranscriptStarts[$n];
    
    my %out;
    
    # If > 1 transcript shares a start, txNumber will be an array of numbers
    # <ArrayRef[Int]> of length 1 or more
    my $txNumber = [ map { $_->[0] } @{ $txStartData->{$txStart} } ];

    my $midPoint;

    if($n > 0) {
      # Look over the upstream txStart, see if it overlaps
      # We take into account the history of previousTxEnd's, for non-adjacent
      # overlapping transcripts
      my $previousTxStart = $allTranscriptStarts[$n - 1];

      for my $txItem ( @{ $txStartData->{$previousTxStart} } ) {
        if($txItem->[1] > $longestPreviousTxEnd) {
          $longestPreviousTxEnd =  $txItem->[1];
          
          $longestPreviousTxNumber = [ $txItem->[0] ];
          next;
        }

        if($txItem->[1] == $longestPreviousTxEnd) {
          push @$longestPreviousTxNumber, $txItem->[0];
        }
      }

      # Take the midpoint of the longestPreviousTxEnd .. txStart - 1 region
      $midPoint = $longestPreviousTxEnd + ( ( ($txStart - 1) - $longestPreviousTxEnd ) / 2 );
    }

    #### Accumulate txNumber or longestPreviousTxNumber for positions between transcripts #### 
    
    # When true, we are not intergenic
    if($longestPreviousTxEnd < $txStart) {
      # txEnd is open, 1-based so include, txStart is closed, 0-based, so stop 1 base before it
      POS_LOOP: for my $pos ( $longestPreviousTxEnd .. $txStart - 1 ) {
        # We expect intergenic, if not log
        if(defined $coveredSitesHref->{$pos} ) {
          $self->log("warn", "Covered by gene: $chr:$pos, skipping");
          delete $coveredSitesHref->{$pos};
          next POS_LOOP;
        }

        if($n == 0 || $pos >= $midPoint) {
          $out{$pos} = $txNumber;
        } else {
          $out{$pos} = $longestPreviousTxNumber;
        }

        #POS_LOOP;
      }
      # $longestPreviousTxEnd < $txStart
    }

    ###### Accumulate txNumber or longestPreviousTxNumber for positions after last transcript in the chr ######
    if ($n == @allTranscriptStarts - 1) {
      my $nearestNumber;
      my $startPoint; 

      #maddingly perl reduce doesn't seem to work, despite this being an array
      my $longestTxEnd = 0;
      foreach (@{ $txStartData->{$txStart} }) {
        $longestTxEnd = $longestTxEnd > $_->[1] ? $longestTxEnd : $_->[1];
      }

      if($longestTxEnd > $longestPreviousTxEnd) {
        $nearestNumber = $txNumber;

        $startPoint = $longestTxEnd;
      } elsif ($longestTxEnd == $longestPreviousTxEnd) {
        $nearestNumber = [@$longestPreviousTxNumber, @$txNumber];

        $startPoint = $longestTxEnd;
      } else {
        $nearestNumber = $longestPreviousTxNumber;

        $startPoint = $longestPreviousTxEnd;
      }

      if($self->debug) {
        say "genome last position is @{[$genomeNumberOfEntries-1]}";
        say "longestTxEnd is $longestTxEnd";
        say "longestPreviousTxEnd is $longestPreviousTxEnd";
        say "current end > previous? " . ($longestTxEnd > $longestPreviousTxEnd ? "YES" : "NO");
        say "previous end equal current? " . ($longestTxEnd == $longestPreviousTxEnd ? "YES" : "NO");
        say "nearestNumber is";
        p $nearestNumber;
        say "starting point in last is $startPoint";
      }

      END_LOOP: for my $pos ( $startPoint .. $genomeNumberOfEntries - 1 ) {
        if(defined $coveredSitesHref->{$pos} ) {
          #this would be an issue with main db gene track entries
          $self->log("warn", "End covered by gene @ $chr:$pos, skipping");
          delete $coveredSitesHref->{$pos};
          next END_LOOP;
        }

        $out{$pos} = $nearestNumber;
      }
    }

    ################# Write nearest gene data to main database ##################
    my $count = 0;
    my %outAccumulator;

    for my $pos (keys %out) {
      if($count >= $self->commitEvery) {
        $self->dbPatchBulkArray($chr, \%outAccumulator);

        undef %outAccumulator;
        $count = 0;
      }

      #Let's store only an array if we have multiple sites
      if( @{ $out{$pos} } == 1) {
        $outAccumulator{$pos} = { $self->nearestDbName => $out{$pos}->[0] };
      } else {
        $outAccumulator{$pos} = { $self->nearestDbName => $out{$pos} };
      }
      
      $count += 1;
    }

    # leftovers
    if(%outAccumulator) {
      $self->dbPatchBulkArray($chr, \%outAccumulator);

      undef %outAccumulator; #force free memory, though shouldn't be needed
    }

    undef %out;
    #TXSTART_LOOP
  }

  $self->log('info', "Finished _writeNearestGenes for $chr");
}

__PACKAGE__->meta->make_immutable;
1;
