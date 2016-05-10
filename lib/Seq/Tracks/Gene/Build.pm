#
##### TODO: Split off the region track building, and insertion of 
###### the pointer to the correct item into RegionTracks
####### Until then, we only have the special case "GeneTrack"
#
### For now: Gene tracks are just weird, and we ignore any user supplied features
# We just give them what we think is useful
# Anything they want in addition to that can be specified as a region track
# Using the existing system, although maybe we will need to specify 
# a "region_features" key
use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Build;

our $VERSION = '0.001';

#TODO: BEFORE BUILDING ANY DATABASE, CHECK THAT THE REFERENCE HAS BEEN MADE

# ABSTRACT: Builds Gene Tracks 
    # Takes care of gene_db, transcript_db, and ngene from the previous Seqant version

#We precalculate everything in this class
#So individual feature names should not need to be known by 
#the class that retrieves this data
#We define what we want at build time, and at run time just look it up.
#Every build track should follow a similar philosophy

# VERSION

=head1 DESCRIPTION

  @class B<Seq::Build::GeneTrack>

  TODO: Describe

Used in:

=for :list

* Seq::Build:
* Seq::Config::SparseTrack
    The base class for building, annotating sparse track features.
    Used by @class Seq::Build
    Extended by @class Seq::Build::SparseTrack, @class Seq::Fetch::Sql,

Extended in: None

=cut

use Moose 2;
use namespace::autoclean;

use Parallel::ForkManager;

use List::Util qw/min first/;

use Seq::Tracks::Gene::Build::TX;
use DDP;

extends 'Seq::Tracks::Build';
with 'Seq::Tracks::Region::Definition', 'Seq::Tracks::Gene::Definition';

# This builder is a bit different. We're going to store not only data in the
# main, genome-wide database (which has sparse stuff)
# but also a special sparse database, the region database
# for this, we need


#what the chromosome field name is in the source file
#know that we would need to update the ucscGeneAref as well
has chrFieldName => (is => 'ro', lazy => 1, default => 'chrom' );
has transcriptStartFieldName => (is => 'ro', lazy => 1, default => 'txStart' );

#give the user some sensible defaults, in case they don't specify anything
#by default we exclude exonStarts and exonEnds
#because they're long, and there's little reason to store anything other than
#naming info in the region database, since we use starts and ends for site-specific stuff
has '+features' => (
  default => sub{ my $self = shift; return $self->defaultUCSCgeneFeatures; },
);

sub BUILD {
  my $self = shift;

  #normal features are mapped at build time
  #We have some extras, so make sure those are mapped before we start 
  #any parallel processing

  $self->getFieldDbName($self->nearestGeneFeatureName);
  $self->getFieldDbName($self->regionReferenceFeatureName);
  $self->getFieldDbName($self->siteFeatureName);
}

#note, if the user chooses to specify features, but doesn't include whatever
#the Build::TX class needs, they'll get an ugly message, and that's just ok
#because they need to know :)

#unlike original GeneTrack, don't remap names
#I think it's easier to refer to UCSC gene naming convention
#Rather than implement our own.
#unfortunately, sources tell me that you can't augment attributes inside 
#of moose roles, so done here
#NOTE: each site can have one or more codons and one or more transcript references
#(we expect to always have the same number of each, but don't currently expliclty check for this)
#This means that when moving to Golang, need to use a type that is either
my $pm = Parallel::ForkManager->new(26);
sub buildTrack {
  my $self = shift;

  my $chrPerFile = scalar $self->all_local_files > 1 ? 1 : 0;

  for my $file ($self->all_local_files) {
    $pm->start and next;
      my $fh = $self->get_read_fh($file);

      #allData holds everything. regionData holds what is meant for the region track
      my %allIdx; # a map <Hash> { featureName => columnIndexInFile}
      my %regionIdx; #like allIdx, but only for features going into the region databae
      my %regionData;
      my %perSiteData;
      
      #lets map, for each chromosome the transcript start, and the transcript number
      my %perChromosomeTranscriptStarts;

      my $wantedChr;
      
      my $txNumber = 0; # this is what our key will be in the region track
      #track how many region track records we've collected
      #to gauge when to bulk insert
      my $regionCount = 0; 

      #We will be inserting two fields into every single site that is covered
      #by a gene
      my $regionReferenceDbFieldName = $self->getFieldDbName($self->regionReferenceFeatureName);
      my $siteFeatureDbFieldName = $self->getFieldDbName($self->siteFeatureName);

      #we'll also store a nearest gene field ($self->nearestGeneFeatureName)
      #but that's done at the end
      #because we can never quite be sure we've gotten all genes, for all 
      #chromosomes, until the very end

      FH_LOOP: while (<$fh>) {
        chomp $_;
        my @fields = split("\t", $_);

        if($. == 1) {
          my $fieldIdx = 0;

          #now store all the features, in the hopes that we have enough
          #for the TX package, and anything else that we consume
          #Notably: we avoid the dictatorship model: this pacakge doesn't need to
          #know every last thing that the packages it consumes require
          #those packages will tell us if they don't have what they need
          for my $field (@fields) {
            $allIdx{$field} = $fieldIdx;
            $fieldIdx++;
          }

          #however, this package absolutely needs the chromosome field
          if( !defined $allIdx{$self->chrFieldName} ) {
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

          next FH_LOOP;
        }

        #Every row (besides header) describes a transcript
        #We want to keep track of which transcript this is (just a number,
        #starting from 0), so that we can insert that 

        #we're not going to insert all required fields into the region database
        #only the stuff that isn't position-dependent
        #because we will pre-calculate all position-dependent effects, as they
        #relate positions in the genome overlapping with these gene ranges
        #Dave's smart suggestion

        #also, we try to avoid assignment operations when not onerous
        #but here not as much of an issue; we expect only say 20k genes
        #and only hundreds of thousands to low millions of transcripts
        my $chr = $fields[ $allIdx{$self->chrFieldName} ];

        #if we have a wanted chr
        if( $wantedChr ) {
          #and it's not equal to the current line's chromosome, which means
          #we're at a new chromosome
          if( $wantedChr ne $chr ) {
            #and if we have region data (we only write region data)
            if(%regionData) {
              #write that data
              $self->dbPatchBulk($self->regionTrackPath($chr), \%regionData);
              #reset the regionData
              %regionData = ();
              #and count of accumulated region sites
              $regionCount = 0;
            }
            #lastly get the new chromosome
            $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
          }
        } else {
          #and if we don't we can just try to get a new chrom
          $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
        }

        if( !$wantedChr ) {
          if($chrPerFile) {
            last FH_LOOP;
          }
          next;
        }

        #if the chromosome is wanted, we should accumulate the features needed
        #the trick for gene tracks is that we only want to add
        #non-core features
        #but we also need to keep track of the rest, to calculate 
        #position-dependent features for the main database

        if($regionCount >= $self->commitEvery && %regionData) {
          $self->dbPatchBulk($self->regionTrackPath($wantedChr), \%regionData);

          $regionCount = 0;
          %regionData = (); #just breaks the reference to allData
        }
        
        #what we want to write
        my $tRegionDataHref;
        my $allDataHref;
        ACCUM_VALUES: for my $fieldName (keys %allIdx) {
          #store the field value
          $allDataHref->{$fieldName} = $fields[ $allIdx{$fieldName} ];
            
          if(!defined $regionIdx{$fieldName} ) {
            next ACCUM_VALUES;
          }

          # if this is a field that we need to store in the region db
          my $dbName = $self->getFieldDbName($fieldName);
          
          $tRegionDataHref->{ $dbName } = $allDataHref->{$fieldName};
        }

        my $txStart = $allDataHref->{$self->transcriptStartFieldName};
        
        if(!$txStart) {
          $self->log('fatal', 'Missing transcript start ( we expected a value @ ' .
            $self->transcriptStartFieldName . ')');
        }

        $perChromosomeTranscriptStarts{$wantedChr}{$txStart} = $txNumber;

        # The responsibility of this BUILD class, as a superset of the Region build class
        # Is to
        # 1) Store a reference to the corresponding entry in the gene database (region database)
        # 2) Store this codon information at some key, which the Tracks::Region::Gene
        # 3) Store transcript errors, if any
        my $txInfo = Seq::Tracks::Gene::Build::TX->new( $allDataHref );

        #since some errors could have been generated, lets capture those
        #and store them in the region database portion
        my @txErrors = $txInfo->allTranscriptErrors;
        if(@txErrors) {
          my $dbName = $self->getFieldDbName($self->geneTrackRegionDatabaseTXerrorName);
          $tRegionDataHref->{$dbName} = \@txErrors;
        }
        
        #we prepare the region data to store in the region database
        #we key on transcript so that we can match our region reference 
        #entry in the main database
        $regionData{$txNumber} = $self->prepareData($tRegionDataHref);

        #And we're done with region database handling
        #So let's move on to the main database entries,
        #which are the ones stored per-position

        #now we move to taking care of the site specific stuff
        #which gets inserted into the main database,
        #for each reference position covered by a transcript
        #"TX" is a misnomer at the moment, in a way, because our only goal
        #with this class is to get back all sites covered by a transcript
        #and for each one of those sites, store the genetic data pertaining to
        #that transcript at that position

        #This is:
        # 1) The codon
        # 2) The strand it's on
        # 3) The codon number (which codon it is in the transcript)
        # 4) The codon "Position" (which position that site occupies in the codon)
        # 5) What type of site it is (As defined by Seq::Site::Definition)
          # ex: non-coding RNA || Coding || 3' UTR etc

        # So from the TX class, we can get this data, and it is stored
        # and fetched by that class. We don't need to know exactly how it's stored
        # but for our amusement, it's packed into a single string
        POS_DATA: for my $pos ($txInfo->allTranscriptSitePos) {
          my $dataHref = {
            #remember, we always insert some very short name in the database
            #to save on space
            #the reference to the region database entry
            #Region tracks also do this, so we get the name from Region::Definition
            $regionReferenceDbFieldName => $txNumber,
            #every detail related to the gene that is specific to that site in the ref
            #like codon sequence, codon number, codon position,
            #strand also stored here, but only for convenience
            #could be taken out later to save space
            $siteFeatureDbFieldName => $txInfo->getTranscriptSite($pos),
          };

          if(defined $perSiteData{$wantedChr}->{$pos} ) {
            for my $key (keys %$dataHref) {
              if(defined $perSiteData{$wantedChr}->{$pos}{$key} ) {
                if(!ref $perSiteData{$wantedChr}->{$pos}{$key} ||
                ref $perSiteData{$wantedChr}->{$pos}{$key} ne 'ARRAY') {
                  $perSiteData{$wantedChr}->{$pos}{$key} = [$perSiteData{$wantedChr}->{$pos}{$key}];
                }
                push @{ $perSiteData{$wantedChr}->{$pos}{$key} }, $dataHref->{$key};
              } else {
                $perSiteData{$wantedChr}->{$pos}{$key} = $dataHref->{$key};
              }
            }

            next POS_DATA;
          }
          $perSiteData{$wantedChr}->{$pos} = $dataHref;
        }

        #iterate how many region sites we've accumulated
        #this will be off by 1 sometimes if we bulk write before getting here
        #see above
        $regionCount++;

        #keep track of the transcript 0-indexed number
        #this becomes the key in the region database
        #and is also what the main database stores as a reference
        #to the region database
        #to save on space vs storing some other transcript id
        $txNumber++;
      }

      #after the FH_LOOP, if anything left over write it
      if(%regionData) {
        if(!$wantedChr) {
          return $self->log('fatal', 'data remains but no chr wanted');
        }
        $self->dbPatchBulk($self->regionTrackPath($wantedChr), \%regionData);
      }

      #we could also do this in a more granular way, at every $wantedChr
      #but that wouldn't completely guarantee the proper accumulation
      #for out of order multi-chr files
      #so we wait until the end
      for my $chr (keys %perSiteData) {
        my $accumDataHref;
        my $accumCount;

        for my $pos (keys %{ $perSiteData{$chr} } ) {
          $accumDataHref->{$pos} = $self->prepareData( $perSiteData{$chr}->{$pos} );
          $accumCount++;
          
          if($accumCount > $self->commitEvery) {
            $self->dbPatchBulk($chr, $accumDataHref);
            $accumDataHref = {};
            $accumCount = 0;
          }
        }
        #leftovers
        if(%$accumDataHref) {
          $self->dbPatchBulk($chr, $accumDataHref);
        }
      }

      # %perChromosomeTranscriptStarts will empty if chr wasn't the requested one
      # and we're using one file per chr
      if(%perChromosomeTranscriptStarts && !$self->noNearestFeatures) {
        $self->makeNearestGenes( \%perChromosomeTranscriptStarts );
      }

    $pm->finish;
  }
  $pm->wait_all_children;
}

#Find all of the nearest genes
#Obviously completely dependent 
#Note: all UCSC refGene data is 0-based
#http://www.noncode.org/cgi-bin/hgTables?db=hg19&hgta_group=genes&hgta_track=refGene&hgta_table=refGene&hgta_doSchema=describe+table+schema
sub makeNearestGenes {
  my ($self, $perChromosomeTranscriptStarts) = @_;
  
  my $ngFeatureDbName = $self->getFieldDbName( $self->nearestGeneFeatureName );
  #$perSiteData holds everything that has been covered
  for my $chr (keys %$perChromosomeTranscriptStarts) {
    #length of the database
    #assumes that the database is built, using reference track
    #TODO: BEFORE BUILDING ANY DATABASE, CHECK THAT THE REFERENCE HAS BEEN MADE
    my $dbEntries = $self->dbGetNumberOfEntries($chr);

    #coveredGenes is either one, or an array
    my @allTranscriptStarts = sort {
      $a <=> $b
    } keys %{ $perChromosomeTranscriptStarts->{$chr} };
  
    my $count = 0;
    my %out;
    my $i = 0;
    for my $txStart (@allTranscriptStarts) {
      my $txNumber = $perChromosomeTranscriptStarts->{$chr}->{$txStart};
      my $txData = $self->prepareData( { $ngFeatureDbName => $txNumber } );
      # say "txData is";
      # p $txData;
      for(my $y = $i; $y < $txStart; $y++) {

        if($count >= $self->commitEvery && %out) {
          #1 flag to merge whatever is held in the $self->name value in the db
          #since this is basically a 2nd insertion step
          $self->dbPatchBulk($chr, \%out, 1);
          %out = ();
          $count = 0;
        }

        $out{$y} = $txData;

        $count++;
      }

      #once we're in one transcript, the nearest is the next closest transcript
      #so let's start with the current txStart as our new baseline position
      $i = $txStart;
    }

    #leftovers
    if(%out) {
      # say "if we had been inserting we would have inserted";
      # p %out;
      $self->dbPatchBulk($chr, \%out, 1);
    }
  }
}
__PACKAGE__->meta->make_immutable;
1;

