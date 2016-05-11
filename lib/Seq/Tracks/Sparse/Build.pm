use 5.10.0;
use strict;
use warnings;
#TODO: TEST to make sure this (and all other fields are still working)
package Seq::Tracks::Sparse::Build;

our $VERSION = '0.001';

# ABSTRACT: Base class for sparse track building
# For now there actually is nothing that extends this. SnpTrack has been
# folded into this, because the only thing that it did differently
# was split two fields on comma, and compute a maf
# So I'm dropping maf and just reporting both allele frequencies, and 
# always split on comma if one is found

# A key limitation of this is that we expect each site to have one record
# For instance: It's perfectly ok for one dbSNP rs # to map to multiple positions
# but it's not ok for one position to have multiple dbSNP rs #'s

=head1 DESCRIPTION

  @class Seq::Tracks::SparseTrack::Build
  Only this package knows how to build a sparse track

  @example

Used in:
=for :list
* Seq::Build

Extended by: none

=cut

#TODO: Error check the input files, for being out of the bounds of the chr
#Do this by enforcing the ref track to have been built, not certain how
#maybe just document that need
#And then do the equivalent call of mdb_stat -e chrN ($ENV->stat() )
use Moose 2;

use Carp qw/ croak /;
use namespace::autoclean;
use List::MoreUtils qw/firstidx/;
use Parallel::ForkManager;
use DDP;

extends 'Seq::Tracks::Build';
#TOOD: make this role work, remove the $reqFields and featureFields stuff below
#with 'Seq::Tracks::Base::MapFields';

#can be overwritten if needed
has chrom_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chrom');
has chromStart_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chromStart');
has chromEnd_field_name => (is => 'ro', isa => 'Str', lazy => 1, default => 'chromEnd');

#TODO: add types here, so that we can check at build time whether 
#the right stuff has been passed
# I don't think this will work, because buildargs in parent will be called
# before this is when lazy
# has '+required_fields' => (
#   default => sub{ [$chrom, $cStart, $cEnd] },
# );

#1 more process than # of chr in human, to allow parent process + simult. 25 chr
#if N < 26 processes needed, N will be used.
my $pm = Parallel::ForkManager->new(26); 
sub buildTrack {
  my $self = shift;

  my $chrPerFile = scalar $self->all_local_files > 1 ? 1 : 0;

  state $chrom = $self->chrom_field_name;
  state $cStart = $self->chromStart_field_name;
  state $cEnd   = $self->chromEnd_field_name;

  state $reqFields = [$chrom, $cStart, $cEnd];

  for my $file ($self->all_local_files) {
    $pm->start and next;
      my $fh = $self->get_read_fh($file);

      my %data = ();
      my $wantedChr;
      
      my $chr;
      my $featureIdxHref;
      my $reqIdxHref;

      # these are fields that may or may not be included in the output
      # and may or may not be required fields
      # These are also fields the user told us they want to either transform
      # or whose values they want to use in deciding whether or not to exclude
      # a row
      my $fieldsToTransformIdx;
      my $fieldsToFilterOnIdx;

      my $count = 0;

      # sparse track should be 1 based
      # we have a method ->zeroBased, but in practice I find it more confusing to use
      my $based = $self->based;

      FH_LOOP: while (<$fh>) {
        chomp $_; #$_ not nec. , but more cross-language understandable
        #this may be too aggressive, like a super chomp, that hits 
        #leading whitespace as well; wouldn't give us undef fields
        #$_ =~ s/^\s+|\s+$//g; #remove trailing, leading whitespace

         #$_ not nec. here, but this is less idiomatic, more cross-language
        my @fields = split("\t", $_);

        if($. == 1) {

          REQ_LOOP: for my $field (@$reqFields) {
            my $idx = firstidx {$_ eq $field} @fields; #returns -1 if not found
            if(~$idx) { #bitwise complement, makes -1 0
              $reqIdxHref->{$field} = $idx;
              next REQ_LOOP; #label for clarity
            }
            
            $self->log('fatal', 'Required field $field missing in $file header');
          }

          # say 'all features wanted are';
          # p @{[$self->allFeatures]};
          
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

          next FH_LOOP;
        }

        #If the user wants to modify the values of any fields, do that first
        for my $fieldName ($self->allFieldsToTransform) {
          $fields[ $fieldsToTransformIdx->{$fieldName} ] = 
            $self->transformField($fieldName, $fields[ $fieldsToTransformIdx->{$fieldName} ] );

            # say "after transformation, $fieldName becomes";
            # p $fields[ $fieldsToTransformIdx->{$fieldName} ];
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

        #say "chr is $chr";

        #this will not work well if chr are significantly out of order
        #because we won't be able to benefit from sequential read/write
        #we could move to building a larger hash of {chr => { pos => data } }
        #but would need to check commit limits then on a per-chr basis
        #easier to just ask people to give sorted files?
        #or could sort ourselves.
        if($wantedChr) {
          #save a few cycles by not reassigning $wantedChr for every pos
          #if we changed chromosomes, lets write the previous chr's data
          if($wantedChr ne $chr) {
            $self->dbPatchBulk($wantedChr, \%data);

            %data = ();
            $count = 0;
            
            $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
          }
        } else {
          $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
        }

        if(!$wantedChr) {
          if($chrPerFile) {
            last FH_LOOP;
          }
          next FH_LOOP;
        }

        #be a bit conservative with the count, since what happens below
        #could bring us all the way to segfault
        if($count >= $self->commitEvery) {
          $self->dbPatchBulk($wantedChr, \%data);

          %data = ();
          $count = 0;
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

        # say "data to print is";
        # p %data;
      }

      #we're done with the file, and stuff is left over;
      if(%data) {
        if(!$wantedChr) {
          return $self->log('fatal', 'After file read, data left, but no wantecChr');
        }
        #let's write that stuff
        $self->dbPatchBulk($wantedChr, \%data);
      }

    $pm->finish;
  }
  
  $pm->wait_all_children;
  $self->log('info', 'finished building: ' . $self->name);
}

__PACKAGE__->meta->make_immutable;

1;

###moved field -> index map to seperate function, since shared with region tracks
###old code for if ($. == 1) {
   # say "fields are";
          # p @fields;

#           REQ_LOOP: for my $field (@$reqFields) {
#             my $idx = firstidx {$_ eq $field} @fields; #returns -1 if not found
#             if(~$idx) { #bitwise complement, makes -1 0
#               $reqIdx{$field} = $idx;
#               next REQ_LOOP; #label for clarity
#             }
            
#             $self->log('error', 'Required field $field missing in $file header');
#           }

#           # say 'all features wanted are';
#           # p @{[$self->allFeatures]};
          
#           FEATURE_LOOP: for my $fname ($self->allFeatures) {
#             my $idx = firstidx {$_ eq $fname} @fields;
#             if(~$idx) { #only non-0 when non-negative, ~0 > 0
#               $featureIdx{$fname} = $idx;
#               next FEATURE_LOOP;
#             }
#             $self->log('warn', "Feature $fname missing in $file header");
#           }
# }