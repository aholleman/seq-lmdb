use 5.10.0;
use strict;
use warnings;

#NOTE: Now just takes the regular CADD file format
#it just will take it compressed
#I think that processing a 200G+ file into a wigFix format
#Is something no one will do
#And maybe a few people will want to (to be seen, trying to lower the barriers)
package Seq::Tracks::Cadd::Build;

use Moose;
extends 'Seq::Tracks::Build';

use Parallel::ForkManager;
use DDP;

#TODO: like with sparse tracks, allow users to map 
#if other, competing predictors have similar enough formats
state $chrom = 'Chrom';
state $pos = 'Pos';
state $alt   = 'Alt';
state $reqFields = [$chrom, $pos, $alt];

#TODO: add types here, so that we can check at build time whether 
#the right stuff has been passed
# I don't think this will work, because buildargs in parent will be called
# before this is when lazy
# has '+required_fields' => (
#   default => sub{ [$chrom, $cStart, $cEnd] },
# );

# before BUILDARGS => sub {
#   my ($orig, $class, $href) = @_;
#   $href->{required_fields} = [$chrom, $cStart, $cEnd];
#   $class->$orig($href);
# }

#1 more process than # of chr in human, to allow parent process + simult. 25 chr
#if N < 26 processes needed, N will be used.


my $pm = Parallel::ForkManager->new(26); 
sub buildTrack {
  my ($self) = @_;
  # $self = $_[0]
  # not shifting to allow goto

  #there can only be ONE
  #the one that binds them
  my ($file) = $self->all_local_files;

  my $fh = $self->get_read_fh($file);

  my %data = ();
  my $wantedChr;
  
  my $chr;
  my $featureIdxHref;
  my $reqIdxHref;

  my $count = 0;

  # sparse track should be 1 based
  # we have a method ->zeroBased, but in practice I find it more confusing to use
  my $based = $self->based;


  FH_LOOP: while (<$fh>) {
    chomp $_; #$_ not nec. , but more cross-language understandable
    #this may be too aggressive, like a super chomp, that hits 
    #leading whitespace as well; wouldn't give us undef fields
    #$_ =~ s/^\s+|\s+$//g; #remove trailing, leading whitespace

    if($. == 1 && ! ~index $_, '#' ) {
      close $fh;
      goto &buildTrackFromHeaderlessWigFix;
     #$_ not nec. here, but this is less idiomatic, more cross-language
    }


    # my @fields = split "\t";

    # my $chr = $fields[0];

    # if($chr ne $wantedChr) {
    #   $self->finishing
    # }
  #   #this will not work well if chr are significantly out of order
  #   #because we won't be able to benefit from sequential read/write
  #   #we could move to building a larger hash of {chr => { pos => data } }
  #   #but would need to check commit limits then on a per-chr basis
  #   #easier to just ask people to give sorted files?
  #   #or could sort ourselves.
  #   if($wantedChr) {
  #     #save a few cycles by not reassigning $wantedChr for every pos
  #     #if we changed chromosomes, lets write the previous chr's data
  #     if($wantedChr ne $chr) {
  #       $self->dbPatchBulk($wantedChr, \%data);

  #       %data = ();
  #       $count = 0;
        
  #       $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
  #     }
  #   } else {
  #     $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
  #   }

  #   if(!$wantedChr) {
  #     if($chrPerFile) {
  #       last FH_LOOP;
  #     }
  #     next;
  #   }

  #   #be a bit conservative with the count, since what happens below
  #   #could bring us all the way to segfault
  #   if($count >= $self->commitEvery) {
  #     $self->dbPatchBulk($wantedChr, \%data);

  #     %data = ();
  #     $count = 0;
  #   }

  #   #let's collect all of our positions
  #   #bed files should be 1 based, but let's just say someone passes in
  #   #something bed-like
  #   #they could override our default 0 value, and we can still get back
  #   #a 0 indexed array of positions
  #   my $pAref;

  #   #chromStart - chromEnd is a half closed range; i.e 0 1 means feature
  #   #exists only at position 0
  #   #this makes a 1 member array if both values are identical
    
  #   #this is an insertion; the only case when start should == stop
  #   #TODO: this could lead to errors with non-snp tracks, not sure if should wwarn
  #   #logging currently is synchronous, and very, very slow compared to CPU speed
  #   if($fields[ $reqIdxHref->{$cStart} ] == $fields[ $reqIdxHref->{$cEnd} ] ) {
  #     $pAref = [ $fields[ $reqIdxHref->{$cStart} ] - $based ];
  #   } else { #it's a normal change, or a deletion
  #     #BED is a half-closed format, so subtract 1 from end
  #     $pAref = [ $fields[ $reqIdxHref->{$cStart} ] - $based 
  #       .. $fields[ $reqIdxHref->{$cEnd} ] - $based - 1 ];
  #   }
  
  #   #now we collect all of the feature data
  #   #coerceFeatureType will return if no type specified for feature
  #   #otherwise will try to coerce the field into the type specified for $name
  #   my $fDataHref;
  #   for my $name (keys %$featureIdxHref) {
  #     $fDataHref->{$name} = 
  #       $self->coerceFeatureType( $name, $fields[ $featureIdxHref->{$name} ] );
  #   }

  #   #get it ready for insertion, one func call instead of for N pos
  #   $fDataHref = $self->prepareData($fDataHref);

  #   for my $pos (@$pAref) {
  #     $data{$pos} = $fDataHref;
  #     $count++;
  #   }

  #   # say "matching positions are";
  #   # p $pAref;
  # }

  # #we're done with the file, and stuff is left over;
  # if(%data) {
  #   if(!$wantedChr) {
  #     return $self->log('error', 'After file read, data left, but no wantecChr');
  #   }
  #   #let's write that stuff
  #   $self->dbPatchBulk($wantedChr, \%data);
  }

  # $pm->wait_all_children;

  # $self->log('info', 'finished building: ' . $self->name);
}

sub buildTrackFromHeaderlessWigFix {
  my $self = shift;

  #there can only be ONE
  #the one that binds them
  my ($file) = $self->all_local_files;

  my $fh = $self->get_read_fh($file);

  my %data = ();
  my $wantedChr;
  
  my @allWantedChr = $self->allWantedChrs;
  
  my $chr;
  my $featureIdxHref;
  my $reqIdxHref;

  my $count = 0;

  my @inputData;
  # sparse track should be 1 based
  # we have a method ->zeroBased, but in practice I find it more confusing to use
  my $based = $self->based;

  FH_LOOP: while (<$fh>) {
    chomp $_; #$_ not nec. , but more cross-language understandable
    #this may be too aggressive, like a super chomp, that hits 
    #leading whitespace as well; wouldn't give us undef fields
    #$_ =~ s/^\s+|\s+$//g; #remove trailing, leading whitespace
    my @fields = split "\t";

    my $chr = $fields[0];

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

        $self->finishBuildingFromHeaderlessWigFix($wantedChr, \@inputData);
        #$self->dbPatchBulk($wantedChr, \%data);

        @inputData = ();
        $count = 0;
        
        $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
      }
    } else {
      $wantedChr = $self->chrIsWanted($chr) ? $chr : undef;
    }

    if(!$wantedChr) {
      next FH_LOOP;
    }

    #be a bit conservative with the count, since what happens below
    #could bring us all the way to segfault
    if($count >= $self->commitEvery) {
      $self->finishBuildingFromHeaderlessWigfix($wantedChr, \@inputData);

      @inputData = ();
      $count = 0;
    }

    $count++;
  }

  #we're done with the file, and stuff is left over;
  if(@inputData) {
    #let's write that stuff
    $self->finishBuildingFromHeaderlessWigFix($wantedChr, \@inputData);
  }

  $pm->wait_all_children;

  $self->log('info', 'finished building: ' . $self->name);
}

#order is alphabetical

sub finishBuildingFromHeaderlessWigfix {
  $pm->start and return;

    my ($self, $chr, $inputFieldsAref) = @_;

    if(!$chr || @$inputFieldsAref) {
      return $self->log('fatal', "Either no chromosome or an empty array 
        provided when writing CADD entries");
    }

    my %posData;
    
    #This file is expected to have the correct order already
    for my $fieldsAref (@$inputFieldsAref) {
      $posData{ $fieldsAref->[1] } = $self->prepareData(
        [$fieldsAref->[2], $fieldsAref->[3], $fieldsAref->[4] ]
      );
    }
    $self->dbPatchBulk($chr, \%posData);
  $pm->finish;
}

__PACKAGE__->meta->make_immutable;
1;
