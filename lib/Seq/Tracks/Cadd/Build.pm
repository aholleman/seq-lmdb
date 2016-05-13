use 5.10.0;
use strict;
use warnings;

#TODO: SHOULD CHECK THAT REFERENCE MATCHES INPUT
#SINCE THIS HAS MAJOR IMPLICATIONS FOR THE SCORES
#ESPECIALLY IN OUR WIGFIX FORMAT

#NOTE: Now just takes the regular CADD file format
#it just will take it compressed
#I think that processing a 200G+ file into a wigFix format
#Is something no one will do
#And maybe a few people will want to (to be seen, trying to lower the barriers)
package Seq::Tracks::Cadd::Build;

use Moose;
extends 'Seq::Tracks::Build';
with 'Seq::Role::DBManager';

use Parallel::ForkManager;
use DDP;

#TODO: like with sparse tracks, allow users to map 
#if other, competing predictors have similar enough formats
# These are only needed if we read from the weird bed-like CADD tab-delim file
# state $chrom = 'Chrom';
# state $pos = 'Pos';
# state $alt   = 'Alt';
# state $reqFields = [$chrom, $pos, $alt];

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

    #TODO: Finish building the read-from-native-cadd file version,
    #should that be of interest.
    
  }
    
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

  my @positions;
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

    #position, A, C, G (or whatever bases, in alphabetical order starting from the reference)
    push @inputData, [ $fields[1], $fields[2], $fields[3], $fields[4] ];

    #be a bit conservative with the count, since what happens below
    #could bring us all the way to segfault
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

    if(!$chr || !@$inputFieldsAref) {
      $self->log('fatal', "Either no chromosome or an empty array 
        provided when writing CADD entries");
    }

    my %posData;
    my $count = 0;

    #This file is expected to have the correct order already
    for my $fieldsAref (@$inputFieldsAref) {
      $posData{ $fieldsAref->[0] } = $self->prepareData(
        [$fieldsAref->[1], $fieldsAref->[2], $fieldsAref->[3] ]
      );

      if($count >= $self->commitEvery) {
        $self->dbPatchBulk($chr, \%posData);

        %posData = ();
        $count = 0;
      }

      $count++;

    }

    if(%posData) {
      $self->dbPatchBulk($chr, \%posData);
    }
    
  $pm->finish;
}

__PACKAGE__->meta->make_immutable;
1;
