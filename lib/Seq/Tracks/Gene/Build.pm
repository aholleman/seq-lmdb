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
use MCE::Loop;

use Seq::Tracks::Gene::Build::TX;
use DDP;

extends 'Seq::Tracks::Build';

#exports regionTrackPath, regionNearestSubTrackName
with 'Seq::Tracks::Region::Definition',
#exports allUCSCgeneFeatures
'Seq::Tracks::Gene::Definition';

#unlike original GeneTrack, don't remap names
#I think it's easier to refer to UCSC gene naming convention

#can be overwritten if needed in the config file, as described in Tracks::Build
has chrom_field_name => (is => 'ro', lazy => 1, default => 'chrom' );
has txStart_field_name => (is => 'ro', lazy => 1, default => 'txStart' );
has txEnd_field_name => (is => 'ro', lazy => 1, default => 'txEnd' );

#give the user some sensible defaults, in case they don't specify anything
#by default we exclude exonStarts and exonEnds
#because they're long, and there's little reason to store anything other than
#naming info in the region database, since we use starts and ends for site-specific stuff
#doing this also guarantees that at BUILD time, we will generate dbNames
#for all features, see Tracks::Base
has '+features' => (
  default => sub{ my $self = shift; return $self->allUCSCgeneFeatures; },
);

sub BUILD {
  my $self = shift;

  #normal features are mapped at build time
  #We have some extras, so make sure those are mapped before we start 
  #any parallel processing

  #nearest genes are pseudo-tracks
  #they're stored under their own track names, but that name
  #is private to the track under which they were defined
  #the implementation details of this are private, no one should care
  #because the track name they use if based on $self->name
  #which is guaranteed to be unique at run time
  $self->getFieldDbName($self->regionNearestSubTrackName);

  #also not a default feature, since for Gene tracks "features" are whatever
  #is stored in the region database
  #initializing here to make sure we store this value (if calling for first time)
  #before any threads get to it
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
  
  # Assume one file per loop, or all sites in one file
  # Tracks::Build warns if it looks like it may not be the case
  for my $file (@allFiles) {
    $pm->start and next;

      my %allIdx; # a map <Hash> { featureName => columnIndexInFile}
      my %regionIdx; #like allIdx, but only for features going into the region databae

      my $fh = $self->get_read_fh($file);

      my $firstLine = <$fh>;
      chomp $firstLine;
   
      #now store all the features, in the hopes that we have enough
      #for the TX package, and anything else that we consume
      #Notably: we avoid the dictatorship model: this pacakge doesn't need to
      #know every last thing that the packages it consumes require
      #those packages will tell us if they don't have what they need
      my $fieldIdx = 0;
      for my $field (split "\t", $firstLine) {
        $allIdx{$field} = $fieldIdx;
        $fieldIdx++;
      }

      #however, this package absolutely needs the chromosome field
      if( !defined $allIdx{$self->chrom_field_name} ) {
        $self->log('fatal', 'must provide chromosome field');
      }

      #and there are some things that we need in the region database
      #as defined by the features YAML config or our default above
      REGION_FEATS: for my $field ($self->allFeatureNames) {
        if(exists $allIdx{$field} ) {
          $regionIdx{$field} = $allIdx{$field};
          next REGION_FEATS; #label for clarity
        }

        #should die here, so $fieldIdx++ not nec strictly
        $self->log('fatal', 'Required $field missing in $file header');
      }

      # In this loop, we build up txStartData, perSiteData, and regionData
      # regionData is what goes into the gene track's region database
      # perSiteData is what goes under the gene track dbName in the main database
      # and txStartData is used to make nearest genes for gene track if requesed
      # this loop also writes out the gene track data
      #Every row (besides header) describes a transcript 
      #MCE says "It is possible that Perl may create a new code ref on subsequent 
      #runs causing MCE models to re-spawn. One solution to this is to declare 
      #global variables, referenced by workers, with "our" instead of "my"."
      my %allData;
      my %regionData;
      my %txStartData;

      my $wantedChr;
      my %txNumbers;

      FH_LOOP: while (<$fh>) {
        chomp;
        my @fields = split("\t", $_);

        my $chr = $fields[ $allIdx{$self->chrom_field_name} ];

        if( ($wantedChr && $wantedChr ne $chr) || !$wantedChr ) {
          $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
        }
        
        if(!$wantedChr) {
          # if not wanted, and we have one chr per file, exit
          if($chrPerFile) {
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

        #store all the data we can find in the input file,
        #for use later in generating transcripts
        $allData{$wantedChr}{$txNumber}{all} = $allDataHref;

        $txNumbers{$wantedChr} += 1;
      }
    
      if(!%allData) {
        #we skipped this chromosome worth of data
        $pm->finish;
      }

      my %perSiteData;
      my %sitesCoveredByTX;

      $self->log('info', "Starting to build trasncripts for $file");

      # one of the slowest parts of the job
      MCE::Loop::init(
        chunk_size => 1,
        max_workers => 6,
        gather => sub {
          my ($chr, $txNumber, $txSitesHref, $txErrorsAref) = @_;

          POS_DATA: for my $pos (keys %$txSitesHref) {
            if( defined $perSiteData{$chr}->{$pos}{$self->dbName} ) {
              push @{ $perSiteData{$chr}->{$pos}{$self->dbName} }, [ $txNumber, $txSitesHref->{$pos} ] ;
              
              next;
            }

            $perSiteData{$chr}->{$pos}{$self->dbName} = [ [ $txNumber, $txSitesHref->{$pos} ] ];

            $sitesCoveredByTX{$chr}{$pos} = 1;
          }

          if(@$txErrorsAref) {
            $regionData{$chr}->{$txNumber}{ $self->getFieldDbName($self->geneTxErrorName) }
              = $txErrorsAref;
          }
        }
      );

      for my $chr (keys %allData) {
        mce_loop {
          my ($mce, $chunk_ref, $chunk_id) = @_;

          my $allDataHref = $allData{$chr}->{$_}{all};

          my $txInfo = Seq::Tracks::Gene::Build::TX->new( $allDataHref );

          MCE->gather($chr, $_, $txInfo->transcriptSites, $txInfo->transcriptErrors);
        } keys %{ $allData{$chr} };
      }

      MCE::Loop::finish;

      undef %allData;

      $self->log("info", "Finished generating all transcript site data");

      ############### Write out all data ##################
      
      $self->log("info", "Starting to write regionData");

        $self->_writeRegionData( \%regionData );

      $self->log("info", "Finished writing regionData");

      undef %regionData;

      $self->log("info", "Starting to write main db perSiteData");

        $self->_writeMainData( \%perSiteData );

      $self->log("info", "Finished writing main db perSiteData");

      undef %perSiteData;

      if(!$self->noNearestFeatures) {
        $self->log("info", "Starting to write writing main db nearest data");
        
          $self->_writeNearestGenes( \%txStartData, \%sitesCoveredByTX );
        
        $self->log("info", "Finished writing main db nearest data");
      }

    $pm->finish;
  }

  $pm->wait_all_children;
}

sub _writeRegionData {
  my ($self, $regionDataHref) = @_;

  my @allChrs = keys %$regionDataHref;

  my $pm = Parallel::ForkManager->new(scalar @allChrs);

  for my $chr (@allChrs) {
    $pm->start and next;
      $self->log('info', "starting to _writeRegionData for $chr");

      my $dbName = $self->regionTrackPath($chr);

      my @txNumbers = keys %{ $regionDataHref->{$chr} };

      my %out;
      my $count = 0;

      for my $txNumber (@txNumbers) {
        if($count >= $self->commitEvery) {
          $self->dbPatchBulk($dbName, \%out);

          undef %out;
          $count = 0;
        }

        #Only region tracks store their data directly, anything going into the
        #main database needs to prepare the data first (store at it's dbName)
        $out{$txNumber} = $regionDataHref->{$chr}{$txNumber};
        
        $count += 1;
      }

      if(%out) {
        $self->dbPatchBulk($dbName, \%out);

        undef %out;
      }

    $pm->finish;
  }

  $pm->wait_all_children;
}

sub _writeMainData {
  my ($self, $mainDataHref) = @_;

  my @allChrs = keys %$mainDataHref;

  my $pm = Parallel::ForkManager->new(scalar @allChrs);

  for my $chr (@allChrs) {
    $pm->start and next;
      $self->log('info', "starting to _writeMainData for $chr");

      my %out;
      my $count = 0;

      for my $pos ( keys %{ $mainDataHref->{$chr} } ) {
        
        if($count >= $self->commitEvery) {
          $self->dbPatchBulk($chr, \%out);

          undef %out;
          $count = 0;
        }

        $out{$pos} = $self->prepareData( $mainDataHref->{$chr}{$pos} );

        $count += 1;
      }

      if(%out) {
        $self->dbPatchBulk($chr, \%out);

        undef %out;
      }

    $pm->finish;
  }

  $pm->wait_all_children;
}

#Find all of the nearest genes
#Obviously completely dependent 
#Note: all UCSC refGene data is 0-based
#http://www.noncode.org/cgi-bin/hgTables?db=hg19&hgta_group=genes&hgta_track=refGene&hgta_table=refGene&hgta_doSchema=describe+table+schema
#We will only look between transcripts, nearest gene of a position covering a gene
#is itself
sub _writeNearestGenes {
  my ($self, $txStartData, $coveredSitesHref) = @_;
  
  #get the nearest gene feature name that we want to use in our database (expect some integer)
  my $nearestGeneDbName = $self->getFieldDbName( $self->regionNearestSubTrackName );
  
  my @allChrs = keys %$txStartData;

  my $pm = Parallel::ForkManager->new(scalar @allChrs);

  # Note, all txStart are 0-based , and all txEnds are 1 based
  # http://genome.ucsc.edu/FAQ/FAQtracks#tracks1
  for my $chr (@allChrs) {
    $pm->start and next;
      $self->log('info', "starting to _writeNearestGenes for $chr");
     
      # Get database length : assumes reference track already in the db
      my $genomeNumberOfEntries = $self->dbGetNumberOfEntries($chr);

      my @allTranscriptStarts = sort {
        $a <=> $b
      } keys %{ $txStartData->{$chr} };

      # Track the longest (further in db toward end of genome) txEnd, because
      #  in  case of overlapping transcripts, want the points that ARENT 
      #  covered by a gene (since those have apriori nearest records: themselves)
      #  This also acts as our starting position
      my $longestPreviousTxEnd = 0;
      my $longestPreviousTxNumber;
      my $longestPreviousTxData;

      TXSTART_LOOP: for (my $n = 0; $n < @allTranscriptStarts; $n++) {
        my $txStart = $allTranscriptStarts[$n];
        
        my %out;
        
        #more than one transcript may share the same transcript start
        #we'll accumulate all of these
        #we only want to check between genes
        #and by doing the following, we will not only do this,
        #but also fit the conceit in which positions in a transcript
        #are "nearest" to that transcript itself
        my $longestTxEnd = 0;
        my $txNumber;

        #we look between the furthest down txEnd in case of multiple transcripts with
        # these same txStart
        # because we only care aboute intergenic positions
        # anything before that is inside of a gene

        for my $txItem ( @{ $txStartData->{$chr}{$txStart} } ) {
          push @$txNumber, $txItem->[0];
          
          if($txItem->[1] > $longestTxEnd) {
            $longestTxEnd = $txItem->[1];
          }
        }

        my $txData = { $nearestGeneDbName => $txNumber };

        my $midPoint;

        if($n > 0) {
          # Look over the downstream txStart, and see if it is longer than the
          # one before it
          # If by some chance multiple tx have the same txEnd, they'll both be included
          # as the nearest (in case current $pos is before the midpoint)
          my $previousTxStart = $allTranscriptStarts[$n - 1];

          for my $txItem ( @{ $txStartData->{$chr}{$previousTxStart} } ) {
            if($txItem->[1] > $longestPreviousTxEnd) {
              $longestPreviousTxEnd =  $txItem->[1];

              $longestPreviousTxNumber = [ $txItem->[0] ];
              next;
            }

            if($txItem->[1] == $longestPreviousTxEnd) {
              push @$longestPreviousTxNumber, $txItem->[0];
            }
          }

          $longestPreviousTxData = { $nearestGeneDbName => $longestPreviousTxNumber };

          # Take the midpoint of the longestPreviousTxEnd .. txStart - 1 region
          $midPoint = $longestPreviousTxEnd + ( ( ($txStart - 1) - $longestPreviousTxEnd ) / 2 );
        }

        if($self->debug) {
          p $txStartData->{$chr}{$txStart};

          say "txStart is $txStart";
          p $txData;
          say "longestTx end is $longestTxEnd";
          p $longestPreviousTxData;
        }

        #### Accumulate txData or previousTxData for positions between transcripts #### 
        
        # One of our previous transcripts overlaps this one
        # This means we've already iterated over the intergenic space between
        if($longestPreviousTxEnd < $txStart) {
          # txEnd is open, 1-based, so starting from that means we're 1 past the end of the tx
          # txStart is closed, 0-based, so stop 1 base before it
          POS_LOOP: for my $pos ( $longestPreviousTxEnd .. $txStart - 1 ) {
            # Record for intergenic only; probably shouldn't be true, so log.
            if(defined $coveredSitesHref->{$chr}{$pos} ) {
              $self->log("warn", "Covered by gene: $chr:$pos, skipping");
              next POS_LOOP;
            }

            if($n == 0 || $pos >= $midPoint) {
              $out{$pos} = $txData;

              if($n > 0) {
                say "after: $pos";
              } else {
                say "no mid: $pos";
              }
              
            } else {
              $out{$pos} = $longestPreviousTxData;

              say "before mid: $pos";
            }

            #POS_LOOP;
          }
          # $longestPreviousTxEnd < $txStart
        }

        ###### Accumulate txData for positions after last transcript in the chr ###      
        if ($n == @allTranscriptStarts - 1) {
          my $endData;
          my $startPoint; 

          if($longestTxEnd > $longestPreviousTxEnd) {
            $endData = $txData;

            $startPoint = $longestTxEnd;
          } elsif ($longestTxEnd == $longestPreviousTxEnd) {
            $endData = { $nearestGeneDbName => [@$longestPreviousTxNumber, @$txNumber] };

            $startPoint = $longestTxEnd;
          } else {
            $endData = $longestPreviousTxData;

            $startPoint = $longestPreviousTxEnd;
          }

          if($self->debug) {
            say "current end > previous? " . $longestTxEnd > $longestPreviousTxEnd ? "YES" : "NO";
            say "previous end equal current? " . $longestTxEnd == $longestPreviousTxEnd ? "YES" : "NO";
            say "endData is";
            p $endData;
            say "starting point in last is $startPoint";
          }

          END_LOOP: for my $pos ( $startPoint .. $genomeNumberOfEntries - 1 ) {
            if(defined $coveredSitesHref->{$chr}{$pos} ) {
              #this would be an issue with main db gene track entries
              $self->log("warn", "End covered by gene @ $chr:$pos, skipping");
              next END_LOOP;
            }

            $out{$pos} = $endData;
          }
          #$n == @allTranscriptStarts - 1
        }

        ################# Write nearest gene data to main database ##################
        my $count = 0;
        my %outAccumulator;

        for my $pos (keys %out) {
          if($count >= $self->commitEvery) {
            $self->dbPatchBulk($chr, \%outAccumulator);

            undef %outAccumulator;
            $count = 0;
          }

          $outAccumulator{$pos} = $self->prepareData( $out{$pos} );

          $count += 1;
        }

        # leftovers
        if(%outAccumulator) {
          $self->dbPatchBulk($chr, \%outAccumulator);

          undef %outAccumulator; #force free memory, though shouldn't be needed
        }

        #TXSTART_LOOP
      }

    # end of chr
    $pm->finish;
  }

  #done 
  $pm->wait_all_children;
}

__PACKAGE__->meta->make_immutable;
1;
