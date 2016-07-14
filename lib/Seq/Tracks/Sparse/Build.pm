use 5.10.0;
use strict;
use warnings;
package Seq::Tracks::Sparse::Build;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class Seq::Tracks::SparseTrack::Build
  Builds any sparse track

=cut

use Mouse 2;

use namespace::autoclean;
use List::MoreUtils qw/firstidx/;
use Parallel::ForkManager;
use Scalar::Util qw/looks_like_number/;

use DDP;

extends 'Seq::Tracks::Build';

# We assume sparse tracks have at least one feature; can remove this requirement
# But will need to update makeMergeFunc to not assume an array of values (at least one key => value)
has '+features' => (required => 1);

#can be overwritten if needed by the usef
has chrom_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chrom');
has chromStart_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chromStart');
has chromEnd_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chromEnd');

# We skip entries that span more than this number of bases
has max_variant_size => (is => 'ro', isa => 'Int', lazy => 1, default => 32);

################# Private ################
# Only 0 based files should be half closed
has _halfClosedOffset => (is => 'ro', init_arg => undef, writer => '_setHalfClosedOffset');

sub BUILD {
  my $self = shift;
  # Use small commit size for sparse tracks, because few values are typically being inserted
  # and each value may be very large; make better use of free pages.
  if($self->commitEvery > 700){ $self->commitEvery(700);}

  $self->_setHalfClosedOffset($self->based == 0 ? 1 : 0);

  if($self->based != 1 && $self->based != 0) {
    $self->log('fatal', "SparseTracks expect based to be 0 or 1"); 
  }
}

# Merge sparse data. We intentionally push undefined (or nil if in Go)
# values, because we want to keep order consistent, so that all records pertaining
# to one position for this track are kept together
# Merge functions are only called if there is an $oldTrackVal
# WARNING: This will not work if you try to build twice, without first deleting
# that track from the database. It will result in nested arrays.
sub makeMergeFunc {
  my $self = shift;
  my $madeIntoArray = {};

  return sub {
    my ($chr, $pos, $trackIdx, $oldTrackVal, $newTrackVal) = @_;
    my @updated = @$oldTrackVal;

    # oldTrackVal and $newTrackVal should both be arrays, with at least one index
    for (my $i = 0; $i < @$newTrackVal; $i++) {
      if($i > $#$oldTrackVal) {
        push @updated, $newTrackVal->[$i];
        next;
      }

      if(!$madeIntoArray->{$chr}{$pos}{$trackIdx}{$i}) {
        $updated[$i] = [$oldTrackVal->[$i]];
        $madeIntoArray->{$chr}{$pos}{$trackIdx}{$i} = 1;
      }

      push @{$updated[$i]}, $newTrackVal->[$i];
    }
    
    return \@updated;
  }
}

sub buildTrack {
  my $self = shift;

  my $pm = Parallel::ForkManager->new(scalar @{$self->local_files});

  for my $file (@{$self->local_files}) {
    $pm->start($file) and next;
      my $fh = $self->get_read_fh($file);

      ############# Get Headers ##############
      my $firstLine = <$fh>;

      my ($featureIdxHref, $reqIdxHref, $fieldsToTransformIdx, $fieldsToFilterOnIdx, $numColumns) = 
        $self->_getHeaderFields($file, $firstLine);

      my @allWantedFeatureIdx = keys %$featureIdxHref;
      ############## Read file and insert data into main database #############
      my %data = ();
      my $wantedChr;

      my $count;

      # Get an instance of the merge function that closes over $self
      # Note that tracking which positinos have been over-written will only work
      # if there is one chromosome per file, or if all chromosomes are in one file
      # At least until we share $madeIntoArray (in makeMergeFunc) between threads
      # Won't be an issue in Go
      my $mergeFunc = $self->makeMergeFunc();
      # Record which chromosomes were recorded for completionMeta
      my %visitedChrs;
      FH_LOOP: while ( my $line = $fh->getline() ) {
        chomp $line;

        my @fields = split("\t", $line);

        if(! $self->_validLine(\@fields, $., $reqIdxHref, $numColumns) ) {
          next FH_LOOP;
        }

        $self->_transform($fieldsToTransformIdx, \@fields);

        if(! $self->_passesFilter($fieldsToFilterOnIdx, \@fields)) {
          next FH_LOOP;
        }

        my $chr = $fields[ $reqIdxHref->{$self->chrom_field_name} ];

        #If the chromosome is new, write any data we have & see if we want new one
        if(!$wantedChr || ($wantedChr && $wantedChr ne $chr) ) {
          if (%data) {
            if(!$wantedChr){ $self->log('fatal', 'Have data, but no chr on line ' . $.)}

            $self->db->dbPatchBulkArray($wantedChr, \%data, undef, $mergeFunc);

            undef %data;
            $count = 0;
          }

          if($self->chrIsWanted($chr) && $self->completionMeta->okToBuild($chr) ) {
            $wantedChr = $chr;
          } else {
            $wantedChr = undef;
          }
        }
        
        if(!$wantedChr) {
          if($self->chrPerFile) { last FH_LOOP; }
          next FH_LOOP;
        }

        my ($start, $end) = $self->_getPositions(\@fields, $reqIdxHref);

        if($end + 1 - $start > $self->max_variant_size) {
          $self->log('info', "Line spans > " . $self->max_variant_size . " skipping: $line");
          next FH_LOOP;
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

        # For now, don't shrink the array; this will make merging less informative
        # Because for those sites that overlap another site, we may lose an "NA"
        # The sparse data may be shorter than @allWantedFeatureIdx because
        # coerceFeatureType may return undefined values if it finds an NA
        # No point in storing those; but we dont' want to make the array not sparse
        # Since that will remove the relationship between index and dbName of the field
        # my $lastUndefinedIndex;
        # SHORTEN_LOOP: for (my $i = $#sparseData; $i >= 0; $i--) {
        #   if(!defined $sparseData[$i]) {
        #     $lastUndefinedIndex = $i;
        #     next SHORTEN_LOOP;
        #   }
        #   last SHORTEN_LOOP;
        # }

        # if($lastUndefinedIndex) {
        #   splice(@sparseData, $lastUndefinedIndex);
        # }

        # #It's formally possible the array shrinks to 0: https://ideone.com/UTqMcF
        # if(!@sparseData) {
        #   next FH_LOOP;
        # }

        #adds $self->dbName to record to locate dbData
        my $namedData = $self->prepareData(\@sparseData);
       
        for my $pos (($start .. $end)) {
          $data{$pos} = $namedData;
          $count++;
        
          if($count >= $self->commitEvery) {
            $self->db->dbPatchBulkArray($wantedChr, \%data, undef, $mergeFunc);

            undef %data;
            $count = 0;
          }
        }

        # Track affected chromosomes for completion recording
        if( !defined $visitedChrs{$wantedChr} ) { $visitedChrs{$wantedChr} = 1 }
      }

      if(%data) {
        if(!$wantedChr) {
          return $self->log('fatal', 'After file read, data left, but no wantecChr');
        }

        $self->db->dbPatchBulkArray($wantedChr, \%data, undef, $mergeFunc);
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

# @param <ArrayRef> $wantedPositionsAref : expects all wanted positions
sub joinTrack {
  my ($self, $wantedChr, $wantedPositionsAref, $wantedFeaturesAref, $callback) = @_;

  my %wantedFeatures = map { $_ => 1 } @$wantedFeaturesAref;

  for my $file ($self->allLocalFiles) {
    my $fh = $self->get_read_fh($file);

    ############# Get Headers ##############
    my $firstLine = <$fh>;
    
    my ($featureIdxHref, $reqIdxHref, $fieldsToTransformIdx, $fieldsToFilterOnIdx, $numColumns) = 
      $self->_getHeaderFields($file, $firstLine);

    my @allWantedFeatureIdx = keys %$featureIdxHref;

    FH_LOOP: while( my $line = $fh->getline() ) {
      chomp $line;
      my @fields = split("\t", $line);

      if(! $self->_validLine(\@fields, $., $reqIdxHref, $numColumns) ) {
        $self->log('info', "Line # $. is invalid: $line");
        next FH_LOOP;
      }

      $self->_transform($fieldsToTransformIdx, \@fields);

      if(! $self->_passesFilter($fieldsToFilterOnIdx, \@fields)) {
        $self->log('info', "Line # $. didn't pass all filters: $line");
        next FH_LOOP;
      }

      my $chr = $fields[ $reqIdxHref->{$self->chrom_field_name} ];

      if($chr ne $wantedChr) {
        if($self->chrPerFile) { last FH_LOOP; }
        next FH_LOOP;
      }

      my ($start, $end) = $self->_getPositions(\@fields, $reqIdxHref);

      my %wantedData;

      FNAMES_LOOP: for my $name (keys %$featureIdxHref) {
        if(! exists $wantedFeatures{$name}) { next; }

        my $value = $self->coerceFeatureType( $name, $fields[ $featureIdxHref->{$name} ] );
          
        $wantedData{$name} = $value;
      }

      for (my $i = 0; $i < @$wantedPositionsAref; $i++) {
        my $wantedStart = $wantedPositionsAref->[$i][0];
        my $wantedEnd = $wantedPositionsAref->[$i][1];

        if( ($start >= $wantedStart && $start <= $wantedEnd)
        || ($end >= $wantedStart && $end <= $wantedEnd) ) {
          &$callback(\%wantedData, $i);
        }
      }
    }
  }
}

sub _getHeaderFields {
  my ($self, $file, $firstLine) = @_;

  my @requiredFields = ($self->chrom_field_name, $self->chromStart_field_name,
    $self->chromEnd_field_name);

  chomp $firstLine;

  my @fields = split "\t", $firstLine;

  my $numColumns = @fields;

  my %featureIdx;
  my %reqIdx;
  my %fieldsToTransformIdx;
  my %fieldsToFilterOnIdx;

  # Which fields are required (chrom, chromStart, chromEnd)
  REQ_LOOP: for my $field (@requiredFields) {
    my $idx = firstidx {$_ eq $field} @fields; #returns -1 if not found
    if(~$idx) { #bitwise complement, makes -1 0
      $reqIdx{$field} = $idx;
      next REQ_LOOP; #label for clarity
    }
    
    $self->log('fatal', "Required field $field missing in $file header");
  }

  # Which fields the user specified under "features" key in config file
  FEATURE_LOOP: for my $fname ($self->allFeatureNames) {
    my $idx = firstidx {$_ eq $fname} @fields;
    if(~$idx) { #only non-0 when non-negative, ~0 > 0
      $featureIdx{ $fname } = $idx;
      next FEATURE_LOOP;
    }
    $self->log('fatal', "Feature $fname missing in $file header");
  }

  # Which fields user wants to filter the value of against some config-defined value
  FILTER_LOOP: for my $fname ($self->allFieldsToFilterOn) {
    my $idx = firstidx {$_ eq $fname} @fields;
    if(~$idx) { #only non-0 when non-negative, ~0 > 0
      $fieldsToFilterOnIdx{ $fname } = $idx;
      next FILTER_LOOP;
    }
    $self->log('fatal', "Feature $fname missing in $file header");
  }

  # Which fields user wants to modify the values of in a config-defined way
  TRANSFORM_LOOP: for my $fname ($self->allFieldsToTransform) {
    my $idx = firstidx {$_ eq $fname} @fields;
    if(~$idx) { #only non-0 when non-negative, ~0 > 0
      $fieldsToTransformIdx{ $fname } = $idx;
      next TRANSFORM_LOOP;
    }
    $self->log('fatal', "Feature $fname missing in $file header");
  }

  return (\%featureIdx, \%reqIdx, \%fieldsToTransformIdx,
    \%fieldsToFilterOnIdx, $numColumns);
}

sub _validLine {
  my ($self, $fieldAref, $lineNumber, $reqIdxHref, $numColumns) = @_;

  if(@$fieldAref != $numColumns) {
    $self->log('warn', "Line $lineNumber has fewer columns than expected, skipping");
    return;
  }

  # Some files are misformatted, ex: clinvar's tab delimited
  if( !looks_like_number( $fieldAref->[ $reqIdxHref->{$self->chromStart_field_name} ] )
  || !looks_like_number(  $fieldAref->[ $reqIdxHref->{$self->chromEnd_field_name} ] ) ) {
    $self->log('warn', "Start or stop doesn't look like a number on line $lineNumber, skipping");
    return;
  }

  return 1;
}

sub _transform {
  my ($self, $fieldsToTransformIdx, $fieldsAref) = @_;
  #If the user wants to modify the values of any fields, do that first
  for my $fieldName ($self->allFieldsToTransform) {
    $fieldsAref->[ $fieldsToTransformIdx->{$fieldName} ] = 
      $self->transformField($fieldName, $fieldsAref->[ $fieldsToTransformIdx->{$fieldName} ] );
  }
}

sub _passesFilter {
  my ($self, $fieldsToFilterOnIdx, $fieldsAref) = @_;
  # Then, if the user wants to exclude rows that don't pass some criteria
  # that they defined in the YAML file, allow that.
  for my $fieldName ($self->allFieldsToFilterOn) {
    if(!$self->passesFilter($fieldName, $fieldsAref->[ $fieldsToFilterOnIdx->{$fieldName} ] ) ) {
      $self->log('info', "$fieldName doesn't pass filter: $fieldsAref->[ $fieldsToFilterOnIdx->{$fieldName} ]");
      return;
    }
  }
  return 1;
}

sub _getPositions {
  my ($self, $fieldsAref, $reqIdxHref) = @_;
  my ($start, $end);
  # This is an insertion; the only case when start should == stop (for 0-based coordinates)
  if($fieldsAref->[ $reqIdxHref->{$self->chromStart_field_name} ] ==
  $fieldsAref->[ $reqIdxHref->{$self->chromEnd_field_name} ] ) {
    $start = $end = $fieldsAref->[ $reqIdxHref->{$self->chromStart_field_name} ] - $self->based;
  } else { 
    #it's a normal change, or a deletion
    #0-based files are expected to be half-closed format, so subtract 1 from end 
    $start = $fieldsAref->[ $reqIdxHref->{$self->chromStart_field_name} ] - $self->based;
    $end = $fieldsAref->[ $reqIdxHref->{$self->chromEnd_field_name} ]
      - $self->based - $self->_halfClosedOffset;
  }

  return ($start, $end);
}
__PACKAGE__->meta->make_immutable;

1;
