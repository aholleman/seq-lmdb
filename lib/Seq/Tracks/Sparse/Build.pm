use 5.10.0;
use strict;
use warnings;
package Seq::Tracks::Sparse::Build;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class Seq::Tracks::SparseTrack::Build
  Builds any sparse track

  @example

=cut

use Moose 2;

use namespace::autoclean;
use List::MoreUtils qw/firstidx/;
use MCE::Loop;
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

  for my $file ($self->allLocalFiles) {
    $pm->start and next;

    my $fh = $self->get_read_fh($file);

    ############# Get Headers ##############
    my $firstLine = <$fh>;

    chomp $firstLine;

    my @fields = split "\t", $firstLine;

    my $featureIdxHref;
    my $reqIdxHref;
    
    # these are fields that may or may not be included in the output
    # and may or may not be required fields
    # These are also fields the user told us they want to either transform
    # or whose values they want to use in deciding whether or not to exclude
    # a row
    my $fieldsToTransformIdx;
    my $fieldsToFilterOnIdx;

    REQ_LOOP: for my $field (@requiredFields) {
      my $idx = firstidx {$_ eq $field} @fields; #returns -1 if not found
      if(~$idx) { #bitwise complement, makes -1 0
        $reqIdxHref->{$field} = $idx;
        next REQ_LOOP; #label for clarity
      }
      
      $self->log('fatal', "Required field $field missing in $file header");
    }

    FEATURE_LOOP: for my $fname ($self->allFeatureNames) {
      my $idx = firstidx {$_ eq $fname} @fields;
      if(~$idx) { #only non-0 when non-negative, ~0 > 0
        $featureIdxHref->{ $fname } = $idx;
        next FEATURE_LOOP;
      }
      $self->log('fatal', "Feature $fname missing in $file header");
    }

    FILTER_LOOP: for my $fname ($self->allFieldsToFilterOn) {
      my $idx = firstidx {$_ eq $fname} @fields;
      if(~$idx) { #only non-0 when non-negative, ~0 > 0
        $fieldsToFilterOnIdx->{ $fname } = $idx;
        next FILTER_LOOP;
      }
      $self->log('fatal', "Feature $fname missing in $file header");
    }

    TRANSFORM_LOOP: for my $fname ($self->allFieldsToTransform) {
      my $idx = firstidx {$_ eq $fname} @fields;
      if(~$idx) { #only non-0 when non-negative, ~0 > 0
        $fieldsToTransformIdx->{ $fname } = $idx;
        next TRANSFORM_LOOP;
      }
      $self->log('fatal', "Feature $fname missing in $file header");
    }

    ########## Get rest of data #########
    my %data = ();
    my $wantedChr;
    
    my $chr;

    # sparse tracks are by default 1 based, but user can override
    my $based = $self->based;

    MCE::Loop::init({
      use_slurpio => 1,
      gather => sub {
        my ($chr, $data) = @_;
        $self->dbPatchBulk($chr, $data);
      },
    });

    mce_loop_f {
      my ($mce, $slurp_ref, $chunk_id) = @_;
      open my $MEM_FH, '<', $slurp_ref;
      binmode $MEM_FH, ':raw';

      my $count = 0;
      my $lineCount = 0;
      FH_LOOP: while (<$MEM_FH>) {
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

        $chr = $fields[ $reqIdxHref->{$chrom} ];

        #If the chromosome is new, write any data we have & see if we want new one
        if($wantedChr ) {
          if($wantedChr ne $chr) {
            if (%data) {
              MCE->gather($wantedChr, \%data);
             
              undef %data;
              $count = 0;
            }
            
            $wantedChr = $self->chrIsWanted($chr) || undef;
          }
        } else {
          $wantedChr = $self->chrIsWanted($chr) || undef;
        }
        
        if(!$wantedChr) {
          if($chrPerFile) {
            $mce->abort;
          }
          
          next FH_LOOP;
        }

        #let's collect all of our positions
        #bed files should be 1 based, but let's just say someone passes in
        #something bed-like
        #they could override our default 0 value, and we can still get back
        #a 0 indexed array of positions
        my $pAref;

        #chromStart - chromEnd is a half closed range; i.e 0 1 means feature
        #exists only at position 0
        #this makes a 1 member array if both values are identical
        
        #this is an insertion; the only case when start should == stop
        #TODO: this could lead to errors with non-snp tracks, not sure if should wwarn
        #logging currently is synchronous, and very, very slow compared to CPU speed
        #example where this happens: clinvar
        if($fields[ $reqIdxHref->{$cStart} ] == $fields[ $reqIdxHref->{$cEnd} ] ) {
          $pAref = [ $fields[ $reqIdxHref->{$cStart} ] - $based ];
        } else { #it's a normal change, or a deletion
          #BED is a half-closed format, so subtract 1 from end
          $pAref = [ $fields[ $reqIdxHref->{$cStart} ] - $based 
            .. $fields[ $reqIdxHref->{$cEnd} ] - $based - 1 ];
        }
      
        #now we collect all of the feature data
        #coerceFeatureType will return if no type specified for feature
        #otherwise will try to coerce the field into the type specified for $name
        my $fDataHref;
        FNAMES_LOOP: for my $name (keys %$featureIdxHref) {
          my $value = $self->coerceFeatureType( $name, $fields[ $featureIdxHref->{$name} ] );
          $fDataHref->{ $self->getFieldDbName($name) } = $value;
        }

        
        #get it ready for insertion, one func call instead of for N pos
        $fDataHref = $self->prepareData($fDataHref);
        
        for my $pos (@$pAref) {
          $data{$pos} = $fDataHref;
          $count++;
        }

        #be a bit conservative with the count, since what happens below
        #could bring us all the way to segfault
        if($count >= $self->commitEvery) {
          MCE->gather($wantedChr, \%data);

          undef %data;
          $count = 0;
        }
        $lineCount++;
      }

      if(%data) {
        if(!$wantedChr) {
          return $self->log('fatal', 'After file read, data left, but no wantecChr');
        }

        MCE->gather($wantedChr, \%data);
        MCE->say("line count was $lineCount");
      }
    } $fh;

    MCE::Loop::finish;
    $pm->finish;
  }

  $pm->wait_all_children;
}

__PACKAGE__->meta->make_immutable;

1;
