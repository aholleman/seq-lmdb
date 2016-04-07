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

package Seq::Tracks::Region::Gene::Build;

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
use DDP;
use Hash::Merge::Simple qw(merge);

extends 'Seq::Tracks::Build';
with 'Seq::Role::IO';

#TODO: make mapfield to index work
#with 'Seq::Tracks::Build::MapFieldToIndex';

#all of our required position-related fields are here;
with 'Seq::Tracks::Region::Gene::Definition';

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
      my %allData;
      
      my %regionIdx; # a map <HashRef> { requiredFieldName => columnIndexInFile}
      my %regionData;

      #collect unique gene names
      my %genes = ();
      
      my $wantedChr;
      
      my $regionIdx = 0; # this is what our key will be in the region track
      my $count = 0;
      FH_LOOP: while (<$fh>) {
        chomp $_;
        my @fields = split("\t", $_);

        if($. == 1) {
          # say "fields are";
          # p @fields;

          ALL_LOOP: for my $field ($self->allGeneTrackKeys) {
            my $idx = firstidx {$_ eq $field} @fields; #returns -1 if not found
            if(~$idx) { #bitwise complement, makes -1 0; this means we found
              $allIdx{$field} = $idx;
              next ALL_LOOP; #label for clarity
            }
          }

          REQ_LOOP: for my $field ($self->allGeneTrackRegionFeatures) {
            my $idx = firstidx {$_ eq $field} @fields; #returns -1 if not found
            if(~$idx) { #bitwise complement, makes -1 0; this means we found
              $regionIdx{$field} = $idx;
              next ALL_LOOP; #label for clarity
            }
            $self->tee_logger('error', 'Required field $field missing in $file header');
            die 'Required field $field missing in $file header';
          }

          next FH_LOOP;
        }

        #we're not going to insert all required fields into the region database
        #only the stuff that isn't position-dependent
        #because we will pre-calculate all position-dependent effects, as they
        #relate positions in the genome overlapping with these gene ranges
        #Dave's smart suggestion

        #also, we try to avoid assignment operations when not onerous
        #but here not as much of an issue; we expect only say 20k genes
        #and only hundreds of thousands to low millions of transcripts
        my $chr = $fields[ $reqIdxHref->{$self->chrKey} ];

        #if we have a wanted chr
        if( $wantedChr ) {
          #and it's not equal to the current line's chromosome
          if( $wantedChr ne $chr ) { # a bit clunky
            #and we have data
            if(%regionData) {
              #write that data
              $self->dbPatchBulk($self->regionPath($chr), \%regionData);
              %regionData = ();
            }
            #and reset the chromosome
            $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
          }
        } else {
          #and if not, we can check if the chromosome is wanted
          #doing this here, allows us to avoid calling chrIsWanted for each line
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
          $self->dbPatchBulk($self->regionPath($wantedChr), \%regionData);

          #however, don't reset  allData; we'll need that later
          $count = 0;
          %regionData = (); #just breaks the reference to allData
        }
      
        my $fToWriteHref;
        for my $f (keys %$featIdxHref) {
          $fToWriteHref->{ $self->getFeatureDbName($f) } =
            $self->prepareData( $featIdxHref->{$f} );
        }

        my $txInfo = Seq::Tracks::Region::Gene::TX->new( $fToWriteHref );

        $fToWriteHref = merge $fToWriteHref, $txInfo->getTxInfo();

        $regionData{$regionIdx} = $fToWriteHref;
        $allData{$regionIdx} = $fToWriteHref;

        $count++; #track for commitEvery
        $regionIdx++; #give each transcript a new entry in the region db
      }

      if(%regionData) {
        if(!$wantedChr) {
          return $self->log('error', 'data remains but no chr wanted');
        }
        $self->dbPatchBulk($self->regionPath($wantedChr), \%regionData);
      }

      #now we have this big hashref of gene stuff. well, let's pass it on 
      #so that we can do all of the positional junk
      $self->doPositionalStuff($wantedChr, \%regionData);
    $pm->finish;
  }
  $pm->wait_all_children;
}

#TODO: this should definitely go into RegionTrack
sub regionPath {
  my ($self, $chr) = @_;

  return $self->name . "/$chr";
}


__PACKAGE__->meta->make_immutable;

1;


# this should be called after Seq::Tracks::Build around BUILDARGS
#http://search.cpan.org/dist/Moose/lib/Moose/Manual/Construction.pod
#TODO: check that this works
#We're adding the above specified hardcoded features to whatever the user provided

#This is more applicable to region tracks
#This needs to be finished, there
# before BUILDARGS => sub {
#   my ($self, $href) = @_;

#   if (!href->{features} ) {
#     $href->{features} = $features;
#     return;
#   }

#   my 
#   for my $name ( @{ $href->{features} } ) {
#     if (ref $name eq 'HASH') {
#       for my $f ( @$features ) {
#         my $name = $f;
#         if (ref $on eq 'HASH') {
#           ($name) = %$on;
#         }

#       } 
#     }
#   }
#   for my $name ( @$features ) {
#     #TODO: finish
#     # if(ref $name eq 'HASH') {
#     #   if()
#     # }
#     #skip anything we've defined, because specify types
#     #bitwise or, returns 0 for -Number only
#     if(~firstidx{ $_ eq $name } @{ $href->{features} } ) {
#       next;
#     }
#     push(@{ $href->{features} }, $name);
#   }
# };