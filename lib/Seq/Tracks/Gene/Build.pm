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
    
      if(!%allData) {
        $pm->finish;
      }

      my %perSiteData;
      my %sitesCoveredByTX;

      MCE::Loop::init(
        chunk_size => 1,
        max_workers => 4,
        gather => sub {
          my ($chr, $txNumber, $txSitesHref, $txErrorsAref) = @_;

          POS_DATA: for my $pos (keys %$txSitesHref) {
            if( defined $perSiteData{$chr}->{$pos}{$self->dbName} ) {
              push @{ $perSiteData{$chr}->{$pos}{$self->dbName} }, [ $txNumber, $txSitesHref->{$pos} ] ;
              
              next;
            }

            $perSiteData{$chr}->{$pos}{$self->dbName} = [ [ $txNumber, $txSitesHref->{$pos} ] ];

            $sitesCoveredByTX{$chr}{pos} = 1;
          }

          if(@$txErrorsAref) {
            $regionData{$chr}{$txNumber}{ $self->getFieldDbName($self->geneTxErrorName) }
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

      $self->log("info", "Finished generating all transcript site data");

      undef %allData;

      $self->_writeRegionData( \%regionData );

      $self->log("info", "Finished writing regionData");

      undef %regionData;

      $self->_writeMainData( \%perSiteData );

      $self->log("info", "Finished writing main (per site) data");

      undef %perSiteData;

      # %txStartData will empty if chr wasn't the requested one
      # and we're using one file per chr
      if(!$self->noNearestFeatures) {
        $self->makeNearestGenes( \%txStartData, \%sitesCoveredByTX );
        $self->log("info", "Finished writing nearest gene (per site) data");
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

      MCE::Loop::init( chunk_size => 'auto', max_workers => 4);

      mce_loop {
        my ($mce, $chunkRef, $chunkId) = @_;
        for my $txNumber (@$chunkRef) {
          # say "writing $txNumber";
          # p $regionDataHref->{$chr}{$txNumber};

          $self->dbPatch( $dbName, $txNumber, $regionDataHref->{$chr}{$txNumber} );
        }
      } @txNumbers;

      MCE::Loop::finish;

    $pm->finish;
  }
  $pm->wait_all_children;
}

sub _writeMainData {
  my ($self, $mainDataHref) = @_;

  my $pm = Parallel::ForkManager->new(26);

  for my $chr (keys %$mainDataHref) {
    $pm->start and next;
      
      MCE::Loop::init( chunk_size => 'auto', max_workers => 4);

      mce_loop {
        my ($mce, $chunkRef, $chunkId) = @_;
        for my $pos (@$chunkRef) {
          # say "writing $pos";
          # p $mainDataHref->{$chr}{$pos};

          $self->dbPatch( $chr, $pos, $mainDataHref->{$chr}{$pos} );
        }
      } keys %{ $mainDataHref->{$chr} };

      MCE::Loop::finish;

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
  
  #we do this per chromosome
  my $pm = Parallel::ForkManager->new(26);

  # Note, all txStart are 0-based , and all txEnds are 1 based
  # http://genome.ucsc.edu/FAQ/FAQtracks#tracks1
  for my $chr (keys %$txStartData) {
    $pm->start and next;

      MCE::Loop::init( chunk_size => 'auto', max_workers => 4);

      $self->log('info', "starting to build nearestData for $chr");
      #length of the database
      #assumes that the database is built using reference track at the least
      my $genomeNumberOfEntries = $self->dbGetNumberOfEntries($chr);

      #coveredGenes is either one, or an array
      my @allTranscriptStarts = sort {
        $a <=> $b
      } keys %{ $txStartData->{$chr} };

      # we keep track of this, because in the case of overlapping transcripts
      # we'll get the midpoint distance between upstream transcript
      # (The current txStart in this loop)
      # and the end of the previous one; because the end of a transcript before THAT
      # one, could have been even longer
      my $longestPreviousTxEnd = 0;

      #our next start is the previous longest end
      my $startingPos = 0;

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

        # say "looking at tx start $n, which has as tart of $txStart";
        # p $txStartData->{$chr}{$txStart};

        # say "longest tx end is $longestTxEnd";
        # say "tx Number is";
        # p @$txNumber;
        # say "txData is";
        # p $txData;

        my $previousTxStart = $n == 0 ? undef : $allTranscriptStarts[$n - 1];

        my ($previousTxNumber, $previousTxEnd, $previousTxData);

        my $midPoint;

        if($previousTxStart) {
          #get the previous txNumber, which may be an array of arrays,
          #or a 1D array containing txNumber, $txEnd 
          for my $txItem ( @{ $txStartData->{$chr}{$previousTxStart} } ) {
            push @$previousTxNumber, $txItem->[0];
            
            if($txItem->[1] > $longestPreviousTxEnd) {
              $longestPreviousTxEnd = $txItem->[1];
            }
          }

          #Our transcripts overalp
          #Since we assume that nearest gene tracks are meant for only positions that aren't
          #already in a transcript, we can skip this position
          #we will set the next starting position as the longer of the two
          #transcript ends
          if($longestPreviousTxEnd > $txStart) {
            $startingPos = $longestPreviousTxEnd > $longestTxEnd ? $longestPreviousTxEnd : $longestTxEnd;
            
            # say "previous transcript, with longestTxEnd $longestPreviousTxEnd, engulfed a txStart";
            next TXSTART_LOOP;
          }
          #we take the midpoint as from the longestPreviousTxEnd
          #because any position before the longestPreviousTxEnd is within the gene
          #and therefore its nearest gene is its own
          $midPoint = $txStart + ( ($txStart - $longestPreviousTxEnd ) / 2 );


          # say "we have previous txStart, $previousTxStart";
          # p $txStartData->{$chr}{$previousTxStart};
          # say "after accumulation of previousTxStarts, have longest previous tx End of $longestPreviousTxEnd ";
          # p $previousTxNumber;
          # say "midPoint is $midPoint, with txStart as $txStart, and longest previous end as $longestPreviousTxEnd";

          $previousTxData = { $nearestGeneDbName => $previousTxNumber };
        }
        #we will scan through the whole genome
        #going from 0 .. first txStart - 1, then txEnd .. next txStart and so on

        #so let's start with the current txEnd as our new baseline position
        #note taht since txEnd is open range, txEnd is also the first base
        #past the end of this transcript
        

        #txEnd is open, 1-based; since $startingPos = $txEnd, we're starting 1 after
        #the end of the last transcript's end
        #txStart is closed, 0-based, so we want to stop 1 base before it (after we're in a gene)
        POS_LOOP: for my $pos ( $startingPos .. $txStart - 1 ) {
          #exclude anything covered by a gene, save space in the database
          #we can conclude that the nearest gene for something covered by a gene
          #is itself (and in overlap case, the list of genes it overlaps)
          if(defined $coveredSitesHref->{$chr}{$pos} ) {
            $self->log("debug", "Covered by gene: $chr:$pos, skipping");
            next POS_LOOP;
          }

          ############ Accumulate the txNumber for the nearest, per position #########
          # not using $self->prepareData( , because that would put this
          # under the gene track designation
          # in order to save a few gigabytes, we're putting it under its own key
          # so that we can store a single value for the main track (@ $self->name )
          if(!defined $previousTxStart || $pos >= $midPoint) {
            $out{$pos} = $txData;

            # if(defined $previousTxStart) {
            #   say "after: $pos";
            #   p %out;
            # } else {
            #   say "no mid: $pos";
            # }
            
          } else {
            #so will give the next one for $y >= $midPoint
            $out{$pos} = $previousTxData;

            # say "before mid: $pos";
          }
        }

        ############# Set the next starting position #################
        $startingPos = $longestPreviousTxEnd > $longestTxEnd ? $longestPreviousTxEnd : $longestTxEnd;
        
        #If we are at the last txStart, then we need to consider
        #The tail of the genome, which is always nearest to the last transcript
        if ($n == @allTranscriptStarts - 1) {
          for my $pos ( $startingPos .. $genomeNumberOfEntries - 1 ) {
            if(defined $coveredSitesHref->{$chr}{$pos} ) {
              $self->log("debug", "End covered by gene @ $chr:$pos, skipping");
              next;
            }

            $out{$pos} = $txData;

            # say "at tail: $pos";
          }
        }

        #Write output, one position at a time, but with some concurrency
        mce_loop {
          my ($mce, $chunkRef, $chunkID) = @_;

          for my $pos (@$chunkRef) {
            $self->dbPatch( $chr, $pos, $out{$pos} );
          }
        } keys %out;

        #end of TXSTART_LOOP
        # say "at end of loop";
      }

      MCE::Loop::finish;

    $pm->finish;
  }

  $pm->wait_all_children;
}


# attempt at concurrency for generating transcripts; giving up on this for now
# say "txErrorDbFieldName is  $txErrorDbFieldName";
#       MCE::Loop::init(
#         chunk_size => 10, 
#         max_workers => 8,
#         user_func => \&_gatherTxSites,
#         gather => sub {
#           my ($chr, $txNumber, $transcriptSitesHref, $errorsAref) = @_;

#           say "chr is $chr";
#           say "txNumber is $txNumber";

#           say "transcriptSiteshref is";
#           p $transcriptSitesHref;


#           POS_DATA: for my $pos (keys %$transcriptSitesHref) {
#             if( defined $perSiteData{$chr}->{$pos}{$self->dbName} ) {
#               push @{ $perSiteData{$chr}->{$pos}{$self->dbName} }, [ $txNumber, $transcriptSitesHref->{$pos} ] ;
              
#               next;
#             }

#             $perSiteData{$chr}->{$pos}{$self->dbName} = [ [ $txNumber, $transcriptSitesHref->{$pos} ] ];

#             $sitesCoveredByTX{$chr}{pos} = 1;
#           }

#           if(@$errorsAref) {
#             $regionData{$chr}->{$txNumber}{$txErrorDbFieldName} = $errorsAref;
#           }
          
#           say "perSiteData is now";
#           p %perSiteData;
#         },
#       );

#       $mce->spawn;
#       $mce->process(\%allData);
#       $mce->shutdown;


# sub _gatherTxSites {
#   my ($mce, $chunk_ref, $chunk_id) = @_;

#   say "in gatherTxSites with";
#   p $chunk_ref;
#   foreach( @{ $chunk_ref } ) {
#     my ($chr, $dataHref) = %$_;

#     my %siteData;

#     for my $txNumber (keys %$dataHref ) {
#       my $allDataHref = $dataHref->{$txNumber}{all};
      
#       my $txInfo = Seq::Tracks::Gene::Build::TX->new( $allDataHref );

#       MCE->gather($chr, $txInfo->transcriptSites, $txInfo->transcriptErrors);
#     }
#   }
# }
__PACKAGE__->meta->make_immutable;
1;
