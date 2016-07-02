use 5.10.0;
use strict;
use warnings;
package Seq::Tracks::Sparse::Build;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class Seq::Tracks::SparseTrack::Build
  Builds any sparse track

=cut

use Moose 2;

use namespace::autoclean;
use List::MoreUtils qw/firstidx/;
use Parallel::ForkManager;

use DDP;

extends 'Seq::Tracks::Build';

#can be overwritten if needed by the usef
has chrom_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chrom');
has chromStart_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chromStart');
has chromEnd_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chromEnd');

my $pm = Parallel::ForkManager->new(26);

sub buildTrack {
  my $self = shift;

  my $chrPerFile = scalar $self->allLocalFiles > 1 ? 1 : 0;

  my $chrom = $self->chrom_field_name;
  my $cStart = $self->chromStart_field_name;
  my $cEnd   = $self->chromEnd_field_name;

  my @requiredFields = ($chrom, $cStart, $cEnd);

  #use small commit size; sparse tracks are small, but their individual values
  #may be quite large, leading to overflow pages
  if($self->commitEvery > 700){
    $self->commitEvery(700);
  }

  # Don't bother storing 3 bytes for a nil value
  # We output NA for any undefined values anyhow
  my $missingValue = 'NA';

  for my $file ($self->allLocalFiles) {
    $pm->start($file) and next;

      my $fh = $self->get_read_fh($file);

      ############# Get Headers ##############
      my $firstLine = <$fh>;
      chomp $firstLine;

      my @fields = split "\t", $firstLine;

      my $featureIdxHref;
      my $reqIdxHref;
      my $fieldsToTransformIdx;
      my $fieldsToFilterOnIdx;

      # Which fields are required (chrom, chromStart, chromEnd)
      REQ_LOOP: for my $field (@requiredFields) {
        my $idx = firstidx {$_ eq $field} @fields; #returns -1 if not found
        if(~$idx) { #bitwise complement, makes -1 0
          $reqIdxHref->{$field} = $idx;
          next REQ_LOOP; #label for clarity
        }
        
        $self->log('fatal', "Required field $field missing in $file header");
      }

      # Which fields the user specified under "features" key in config file
      FEATURE_LOOP: for my $fname ($self->allFeatureNames) {
        my $idx = firstidx {$_ eq $fname} @fields;
        if(~$idx) { #only non-0 when non-negative, ~0 > 0
          $featureIdxHref->{ $fname } = $idx;
          next FEATURE_LOOP;
        }
        $self->log('fatal', "Feature $fname missing in $file header");
      }

      # Which fields user wants to filter the value of against some config-defined value
      FILTER_LOOP: for my $fname ($self->allFieldsToFilterOn) {
        my $idx = firstidx {$_ eq $fname} @fields;
        if(~$idx) { #only non-0 when non-negative, ~0 > 0
          $fieldsToFilterOnIdx->{ $fname } = $idx;
          next FILTER_LOOP;
        }
        $self->log('fatal', "Feature $fname missing in $file header");
      }

      # Which fields user wants to modify the values of in a config-defined way
      TRANSFORM_LOOP: for my $fname ($self->allFieldsToTransform) {
        my $idx = firstidx {$_ eq $fname} @fields;
        if(~$idx) { #only non-0 when non-negative, ~0 > 0
          $fieldsToTransformIdx->{ $fname } = $idx;
          next TRANSFORM_LOOP;
        }
        $self->log('fatal', "Feature $fname missing in $file header");
      }

      my @allWantedFeatureIdx = keys %$featureIdxHref;
      ############## Read file and insert data into main database #############
      my %data = ();
      my $wantedChr;

      # The default BED format is 0-based: https://genome.ucsc.edu/FAQ/FAQformat.html#format1
      # Users can override this by setting $self->based;
      my $based = $self->based;
      my $count;

      # Record which chromosomes were recorded for completionMeta
      my %visitedChrs;
      FH_LOOP: while(<$fh>) {
        chomp;

        my @fields = split("\t", $_);

        #If the user wants to modify the values of any fields, do that first
        for my $fieldName ($self->allFieldsToTransform) {
          $fields[ $fieldsToTransformIdx->{$fieldName} ] = 
            $self->transformField($fieldName, $fields[ $fieldsToTransformIdx->{$fieldName} ] );
        }

        # Then, if the user wants to exclude rows that don't pass some criteria
        # that they defined in the YAML file, allow that.
        for my $fieldName ($self->allFieldsToFilterOn) {
          #say "testing $fieldName filter, whose value is " . $fields[ $fieldsToFilterOnIdx->{$fieldName} ];
          if(!$self->passesFilter($fieldName, $fields[ $fieldsToFilterOnIdx->{$fieldName} ] ) ) {
            #say "$fieldName doesn't pass with value " . $fields[ $fieldsToFilterOnIdx->{$fieldName} ];
            next FH_LOOP;
          }
        }

        my $chr = $fields[ $reqIdxHref->{$chrom} ];

        #If the chromosome is new, write any data we have & see if we want new one
        if(!$wantedChr || ($wantedChr && $wantedChr ne $chr) ) {
          if (%data) {
            if(!$wantedChr){ $self->log('fatal', 'Have data, but no chr on line ' . $.)}

            $self->dbPatchBulkArray($wantedChr, \%data);

            undef %data;
            $count = 0;
          }

          if($$self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr) ) {
            $wantedChr = $chr;
          } else {
            $wantedChr = undef;
          }
        }
        
        if(!$wantedChr) {
          if($chrPerFile) {
            last FH_LOOP;
          }
          
          next FH_LOOP;
        }

        my $pAref;
        
        #this is an insertion; the only case when start should == stop
        if($fields[ $reqIdxHref->{$cStart} ] == $fields[ $reqIdxHref->{$cEnd} ] ) {
          $pAref = [ $fields[ $reqIdxHref->{$cStart} ] - $based ];
        } else { 
          #it's a normal change, or a deletion
          #BED is a 0-based, half-closed format, so subtract 1 from end
          $pAref = [ $fields[ $reqIdxHref->{$cStart} ] - $based 
            .. $fields[ $reqIdxHref->{$cEnd} ] - $based - 1 ];
        }
      
        # Collect all of the feature data as an array
        # Coerce the field into the type specified for $name, if coercion exists
        my @sparseData;
        # Initialize to the size wanted, so we can place in the right index
        $#sparseData = $#allWantedFeatureIdx;

        # Get the field values after transforming them to desired types
        FNAMES_LOOP: for my $name (keys %$featureIdxHref) {
          my $value = $self->coerceFeatureType( $name, $fields[ $featureIdxHref->{$name} ] );
          
          $sparseData[ $self->getFieldDbName($name) ] = $value;
        }

        #adds $self->dbName to record to locate dbData
        my $namedData = $self->prepareData(\@sparseData);
       
        for my $pos (@$pAref) {
          $data{$pos} = $namedData;
          $count++;
        }

        if($count >= $self->commitEvery) {
          $self->dbPatchBulkArray($wantedChr, \%data);

          undef %data;
          $count = 0;
        }

        # Track affected chromosomes for completion recording
        if( !defined $visitedChrs{$chr} ) { $visitedChrs{$chr} = 1 }
      }

      if(%data) {
        if(!$wantedChr) {
          return $self->log('fatal', 'After file read, data left, but no wantecChr');
        }

        $self->dbPatchBulkArray($wantedChr, \%data);
      }

      # Record completion. Safe because detected errors throw, kill process
      foreach (keys %visitedChrs) {
        $self->completionMeta->recordCompletion($_);
      }

    $pm->finish(0);
  }

  my @failed;
  $pm->run_on_finish(sub {
    my ($pid, $exitCode, $fileName) = @_;

    $self->log('debug', "Got exitCode $exitCode for $fileName");

    if($exitCode != 0) { $self->log('fatal', "Got exitCode $exitCode for $fileName") }
  });

  $pm->wait_all_children;

  return @failed == 0 ? 0 : (\@failed, 255);
}

__PACKAGE__->meta->make_immutable;

1;
