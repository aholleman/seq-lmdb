#
##### TODO: Split off the region track building, and insertion of 
###### the pointer to the correct item into RegionTracks
####### Until then, we only have the special case "GeneTrack"
#
use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::GeneTrack::Build;

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

extends 'Seq::Tracks::Build';
with 'Seq::Role::IO', 'Seq::Tracks::Build::MapFieldToIndex',
'Seq::Tracks::GeneTrack::Definition' => {
  #required_fields , since it uses an underscore, we know it can be 
  #set in YAML config.
  -alias => { required_fields => 'requiredGeneTrackFields'},
  -exclude => 'requiredGeneTrackFields',
};

#unlike original GeneTrack, don't remap names
#I think it's easier to refer to UCSC gene naming convention
#Rather than implement our own.

#do we want exonCount?


#what goes into the region track
#in a normal region track this would be set via -feature : 1 \n 2 \n 3 YAML
state $features = ['name'];

has '+required_fields' => (
  default => sub{$reqFields},
);

# this should be called after Seq::Tracks::Build around BUILDARGS
#http://search.cpan.org/dist/Moose/lib/Moose/Manual/Construction.pod
#TODO: check that this works
around BUILDARGS => sub {
  my ($orig, $class, $href) = @_;

  for my $name (@$features) {
    #bitwise or, returns 0 for -Number only
    if(~firstidx{ $_ eq $name } @{ $href->{features} } ) {
      next;
    }
    push(@{ $href->{features} }, $name);
  }
  $class->$orig($href);
};

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
      my %reqIdx = ();

      #allData holds everything. regionData holds what is meant for the region track
      my %allData = ();
      my %regionData = ();

      #collect unique gene names
      my %genes = ();
      
      my $wantedChr;

      my $featIdxHref; # a map <HashRef> { featureName => columnIndexInFile}
      my $reqIdxHref; # a map <HashRef> { requiredFieldName => columnIndexInFile}

      #start with 0, we use the same array index method as with the main db
      my $geneNumber = 0;

      #keep a count of geneNumbers, and reset if > $self->commitEvery;
      my $count = 0;
      FH_LOOP: while (<$fh>) {
        chomp $_;
        my @fields = split("\t", $_);

        if($. == 1) {
          my ($reqIdxHref, $err) = $self->mapRequiredFields(\@fields);
          if($err) {
            $self->tee_logger('error', $err);
          }

          my $featIdxHref = $self->mapFeatureFields(\@fields);
          # say "featureIdx is";
          # p %featureIdx;
          #exit;
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
        my $chr = $fields[ $reqIdxHref->{$chr} ];

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

        if(!exists $genes{ $fields[ $featIdxHref->{name} ] } ) {
          my $geneName = $fields[ $featIdxHref->{name} ]; #for clarity

          #For now we only store the name
          #Later we can store other stuff
          $regionData{$geneNumber}{name} = $self->prepareData($geneName);
          $geneNumber++;
          $count++; #this only tracks regionData
        }


        $allData{$geneNumber} = $self->prepareData({

        });

      }

      if(%regionData) {
        if(!$wantedChr) {
          $self->tee_logger('error', 'data remains but no chr wanted');
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
