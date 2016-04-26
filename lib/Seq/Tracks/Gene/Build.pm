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
use List::MoreUtils::XS qw(firstidx);

use Seq::Tracks::Gene::Build::TX;

extends 'Seq::Tracks::Build';
with 'Seq::Tracks::Region::Definition';

#some default fields, some of which are required
#TODO: allow people to remap the names of required fields if their source
#file doesn't match (a bigger issue for sparse track than gene track)
state $ucscGeneAref = [
  'chrom',
  'strand',
  'txStart',
  'txEnd',
  'cdsStart',
  'cdsEnd',
  'exonCount',
  'exonStarts',
  'exonEnds',
  'name',
  'kgID',
  'mRNA',
  'spID',
  'spDisplayID',
  'geneSymbol',
  'refseq',
  'protAcc',
  'description',
  'rfamAcc',
];

has chrFieldName => (is => 'ro', lazy => 1, default => sub{ $ucscGeneAref->[0] } );

#just the stuff meant for the region database, by default we exclude exonStarts and exonEnds
#because they're long, and there's little reason to store anything other than
#naming info in the region database, since we use starts and ends for site-specific stuff
has '+features' => (
  default => sub{ grep { $_ ne 'exonStarts' && $_ ne 'exonEnds'} @$ucscGeneAref; },
);

has siteFeatureName => (is => 'ro', init_arg => undef, lazy => 1, default => 'site');

#unlike original GeneTrack, don't remap names
#I think it's easier to refer to UCSC gene naming convention
#Rather than implement our own.
#unfortunately, sources tell me that you can't augment attributes inside 
#of moose roles, so done here

#I don't think this will work, around BUILDARGS may not
#get the default value in its href
# has '+features' => (
#   init_arg => undef,
#   default => sub{ my $self = shift; return $self->featureOverride },
# );

# has '+required_fields' => (
#   init_arg => undef,
#   default => sub{ my $self = shift; return $self->requiredFieldOverride },
# );

#Gene tracks are a bit weird, even compared to region tracks
#so we need to store things a bit differently
# before BUILDARGS => sub {
#   my ($orig, $class, $href) = @_;
#   $href->{required_fields} = $Seq::Tracks::Region::Gene::Definition::reqFields;
#   $href->{features} = $Seq::Tracks::Region::Gene::Definition::featureFields;
#   $class->$orig($href);
# }

# This builder is a bit different. We're going to store not only data in the
# main, genome-wide database (which has sparse stuff)
# but also a special sparse database, the region database
# for this, we need
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
      
      my $wantedChr;
      
      my $txNumber = 0; # this is what our key will be in the region track
      #track how many region track records we've collected
      #to gauge when to bulk insert
      my $count = 0; 

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
            $self->tee_logger('error', 'must provide chromosome field');
          }

          #and there are some things that we need in the region database
          #as defined by the features YAML config or our default above
          REGION_FEATS: for my $field ($self->allFeatureNames) {
            if(exists $allIdx{$field} ) {
              $regionIdx{$field} = $allIdx{$field};
              next REGION_FEATS; #label for clarity
            }

            #should die here, so $fieldIdx++ not nec strictly
            $self->tee_logger('error', 'Required $field missing in $file header');
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
              $count = 0;
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

        if($count >= $self->commitEvery) {
          $self->dbPatchBulk($self->regionTrackPath($wantedChr), \%regionData);

          $count = 0;
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

        # The responsibility of this BUILD class, as a superset of the Region build class
        # Is to
        # 1) Store a reference to the corresponding entry in the gene database (region database)
        # 2) Store this codon information at some key, which the Tracks::Region::Gene
        # will know how to fetch.
        # and then, of course, to actually insert that into the database
        my $txInfo = Seq::Tracks::Gene::Build::TX->new( $allDataHref );

        my $sHref;
        my $sCount;
        for my $pos ($txInfo->allTranscriptSitePos) {
          $sHref->{$pos} = $self->prepareData({
            #remember, we always insert some very short name in the database
            #to save on space
            #the reference to the region database entry
            $self->getFieldDbName($self->regionReferenceFeatureName) => $txNumber,
            #every detail related to the gene that is specific to that site in the ref
            #like codon sequence, codon number, codon position,
            #strand also stored here, but only for convenience
            #could be taken out later to save space
            $self->getFieldDbName($self->siteFeatureName) => $txInfo->getTranscriptSite($pos),
          });

          if($sCount > $self->commitEvery) {
            $self->dbPatchBulk($wantedChr, $sHref);
            $sHref = {};
            $sCount = 0;
          } else {
            $sCount++;
          }
        }

        #if anything left over for the site, write it
        if(%$sHref) {
          $self->dbPatchBulk($wantedChr, $sHref);
        }

        #iterate how many region sites we've accumulated
        #this will be off by 1 sometimes if we bulk write before getting here
        #see above
        $count++;

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
          return $self->log('error', 'data remains but no chr wanted');
        }
        $self->dbPatchBulk($self->regionTrackPath($wantedChr), \%regionData);
      }

    $pm->finish;
  }
  $pm->wait_all_children;
}

__PACKAGE__->meta->make_immutable;
1;
