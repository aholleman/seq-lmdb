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


my $pm = Parallel::ForkManager->new(26);

# 1) Store a reference to the corresponding entry in the gene database (region database)
# 2) Store this codon information at some key, which the Tracks::Region::Gene
# 3) Store transcript errors, if any
# 4) Write region data
# 5) Write gene track data in main db
# 6) Write nearest genes if user wants those
sub buildTrack {
  my $self = shift;

  my $chrPerFile = scalar $self->allLocalFiles > 1 ? 1 : 0;

  # We assume one file per loop,
  # Or all sites in one file
  # Enforce by BUILD.pm
  for my $file ($self->allLocalFiles) {
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

        if($wantedChr && $wantedChr ne $chr) {
          $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
        } elsif(!$wantedChr) {
          if( $self->chrIsWanted($chr) ) {
            $wantedChr = $chr;
            next FH_LOOP;
          }

          # if not wanted, and we have one chr per file, exit
          if($chrPerFile) {
            last FH_LOOP;
          }

          #not wanted, but multiple chr per file, skip
          next FH_LOOP;
        }
        
        my $txNumber = $txNumbers{$wantedChr} || 0;

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
          $regionData{$wantedChr}{$txNumber}->{ $fieldDbName } = $allDataHref->{$fieldName};
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

        # Keep track of our 0-indexed transcript refreence numbers
        $txNumbers{$wantedChr}++;
      }
  
      my %perSiteData;
      my %sitesCoveredByTX;

      #I wanted to parallelize, but parallel forkmanager has errors
      #periodically, due to Storable failure
      #No more time to spend on this.
            
      #if we have > 1 chr in this file, write separately
      for my $chr (keys %allData) {
        for my $txNumber ( keys %{ $allData{$chr} } ) {
          my $allDataHref = $allData{$chr}{$txNumber}{all};

          my $txInfo = Seq::Tracks::Gene::Build::TX->new( $allDataHref );

          my %siteData;

          POS_DATA: for my $pos ($txInfo->allTranscriptSitePos) {
            if(defined $perSiteData{$chr}->{$pos}{$self->dbName} ) {
              push @{ $perSiteData{$chr}->{$pos}{$self->dbName} },
                [$txNumber, $txInfo->getTranscriptSite($pos) ] ;
              next;
            }

            $perSiteData{$chr}->{$pos}{$self->dbName} = [ [ $txNumber, $txInfo->getTranscriptSite($pos) ] ];

            $sitesCoveredByTX{$chr}{pos} = 1;
          }

          $regionData{$chr}{$txNumber}{ $self->getFieldDbName($self->geneTxErrorName) }
            = $txInfo->transcriptErrors;
        }
      }

      undef %allData;

      $self->_writeRegionData( \%regionData );

      undef %regionData;

      $self->_writeMainData( \%perSiteData );

      undef %perSiteData;

      # %txStartData will empty if chr wasn't the requested one
      # and we're using one file per chr
      if($self->noNearestFeatures) {
        $self->makeNearestGenes( \%txStartData, \%sitesCoveredByTX );
      }

    $pm->finish;
  }

  $pm->wait_all_children;
}

sub _writeRegionData {
  my ($self, $regionDataHref) = @_;

  my $pm = Parallel::ForkManager->new(26);

  for my $chr (keys %$regionDataHref) {
    $pm->start and next;
      my $dbName = $self->regionTrackPath($chr);

      my @txNumbers = keys %$regionDataHref;

      if(@txNumbers <= $self->commitEvery) {
        $self->dbPatchBulk($dbName, $regionDataHref->{$chr} );
        return;
      }

      my %out;
      my $count;
      for my $txNumber (@txNumbers) {
        $out{$txNumber} = $regionDataHref->{$chr}{$txNumber};
        $count++;

        if($count >= $self->commitEvery) {
          $self->dbPatchBulk($dbName, \%out);
          $count = 0;
          undef %out;
        }
      }

      #remains
      if(%out) {
        $self->dbPatchBulk($dbName, \%out);
      }

    $pm->finish;
  }
  $pm->wait_all_children;
}

sub _writeMainData {
  my ($self, $mainDataHref) = @_;

  my $pm = Parallel::ForkManager->new(32);

  for my $chr (keys %$mainDataHref) {
    $pm->start and next;

      my %out;
      my $count = 0;

      for my $pos (keys %{$mainDataHref->{$chr} } ) {
        if($count >= $self->commitEvery) {
          $self->dbPatchBulk($chr, \%out);
          undef %out;
          $count = 0;
        }

        $out{$pos} = $mainDataHref->{$chr}{$pos};
      }

      if(%out) {
        $self->dbPatchBulk($chr, \%out);
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
sub makeNearestGenes {
  my ($self, $txStartData, $coveredSitesHref) = @_;
  
  #get the nearest gene feature name that we want to use in our database (expect some integer)
  my $nearestGeneDbName = $self->getFieldDbName( $self->regionNearestSubTrackName );
    
  #set a short commit, because we may be using multiple writers 
  #per chr which can lead to runaway inflation
  $self->commitEvery(1e2);

  #we do this per chromosome
  my $pm = Parallel::ForkManager->new(26);

  for my $chr (keys %$txStartData) {
    $pm->start and next;
      #length of the database
      #assumes that the database is built using reference track at the least
      my $genomeNumberOfEntries = $self->dbGetNumberOfEntries($chr);

      #we can write many sites in parallel
      #if running one chr per file, this will lead to good use of HGCC/ amazon
      my $pm2 = Parallel::ForkManager->new(32);

      #coveredGenes is either one, or an array
      my @allTranscriptStarts = sort {
        $a <=> $b
      } keys %{ $txStartData->{$chr} };

      my $startingPos = 0;

      for (my $n = 0; $n < @allTranscriptStarts; $n++) {
        my $txStart = $allTranscriptStarts[$n];

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
        if( @{ $allTranscriptStarts[$n] } > 1 ) {
          foreach ( @{ $allTranscriptStarts[$n] } ) {
            push @$txNumber, $_->[0];
            
            if($_->[1] > $longestTxEnd) {
              $longestTxEnd = $_->[1];
            }
          }
        } else {
          ($txNumber, $longestTxEnd) = @$_;
        }

        my $txData = { $nearestGeneDbName => $txNumber };

        my $previousTxStart = $allTranscriptStarts[$n - 1];

        my ($previousTxNumber, $previousTxEnd, $previousTxData);

        my $midPoint;

        if($previousTxStart) {
          my $longestPreviousTxEnd = 0;
          #get the previous txNumber, which may be an array of arrays,
          #or a 1D array containing txNumber, $txEnd
          if(@{ $txStartData->{$chr}{$previousTxStart} } > 1) {
            foreach ( @{ $txStartData->{$chr}{$previousTxStart} } ) {
              push @$previousTxNumber, $_->[0];
              if($_->[1] > $longestPreviousTxEnd) {
                $longestPreviousTxEnd = $_->[1];
              }
            }
          } else {
            $previousTxNumber = $txStartData->{$chr}{$previousTxStart}[0];
            $longestPreviousTxEnd = $txStartData->{$chr}{$previousTxStart}[1];
          }
            
          #we take the midpoint as from the longestPreviousTxEnd
          #because any position before the longestPreviousTxEnd is within the gene
          #and therefore its nearest gene is its own
          $midPoint = $txStart + ( ($txStart - $longestPreviousTxEnd ) / 2 );

          $previousTxData = { $nearestGeneDbName => $previousTxNumber };
        }

        #we will scan through the whole genome
        #going from 0 .. first txStart - 1, then txEnd .. next txStart and so on

        #so let's start with the current txEnd as our new baseline position
        #note taht since txEnd is open range, txEnd is also the first base
        #past the end of this transcript
        my $count = 0;
        my %out;

        #txStart is closed, meaning included in a transcript, so stop before the end
        for my $pos ( $startingPos .. $txStart - 1 ) {
          #exclude anything covered by a gene, save space in the database
          #we can conclude that the nearest gene for something covered by a gene
          #is itself (and in overlap case, the list of genes it overlaps)
          if(defined $coveredSitesHref->{$chr}{$pos} ) {
            $self->log("debug", "Covered by gene: $chr:$pos, skipping");
            next;
          }

          if($count >= $self->commitEvery && %out) {
            $self->dbPatchBulk($chr, \%out);
            
            undef %out;
            $count = 0;
          }

          $count++;

          ############ Accumulate the txNumber for the nearest, per position #########
          # not using $self->prepareData( , because that would put this
          # under the gene track designation
          # in order to save a few gigabytes, we're putting it under its own key
          # so that we can store a single value for the main track (@ $self->name )
          if($previousTxStart && $pos < $midPoint) {
            $out{$pos} = $txData;
          } else {
            #so will give the next one for $y >= $midPoint
            $out{$pos} = $previousTxData;
          }
        }

        $startingPos = $longestTxEnd;

        #We're done looking at this transcript start
        #If we also happne to be at the last txStart, then we need to consider
        #The tail of the genome, which is always nearest to the last transcript
        if ($n == @allTranscriptStarts) {
          for my $pos ( $startingPos .. $genomeNumberOfEntries - 1 ) {
            if(defined $coveredSitesHref->{$chr}{$pos} ) {
              $self->log("debug", "End covered by gene @ $chr:$pos, skipping");
              next;
            }

            if($count >= $self->commitEvery && %out) {
              $self->dbPatchBulk($chr, \%out);
              
              undef %out;
              $count = 0;
            }

            $out{$pos} = $txData;

            $count++;
          }
        }

        #leftovers
        if(%out) {
          $self->dbPatchBulk($chr, \%out);
          undef %out;
          $count = 0;
        }
      }

    $pm->finish;
  }

  $pm->wait_all_children;
}

__PACKAGE__->meta->make_immutable;
1;
