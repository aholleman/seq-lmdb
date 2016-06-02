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

# use Parallel::ForkManager;
use DDP;

#TODO: like with sparse tracks, allow users to map 
#if other, competing predictors have similar enough formats
# These are only needed if we read from the weird bed-like CADD tab-delim file
# state $chrom = 'Chrom';
# state $pos = 'Pos';
# state $alt   = 'Alt';
# state $reqFields = [$chrom, $pos, $alt];

use MCE::Loop;

#my $pm = Parallel::ForkManager->new(26); 
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


  if( ! ~index $fh->getline(), '#') {
    close $fh;
    goto &buildTrackFromHeaderlessWigFix;
  }

  # finish for regular cadd file
  # FH_LOOP: while (my $line = $fh->getline() ) {
  #   chomp $line; #$_ not nec. , but more cross-language understandable
  #   #this may be too aggressive, like a super chomp, that hits 
  #   #leading whitespace as well; wouldn't give us undef fields
  #   #$_ =~ s/^\s+|\s+$//g; #remove trailing, leading whitespace

   

  #   #TODO: Finish building the read-from-native-cadd file version,
  #   #should that be of interest.
    
  # }
    
}

sub buildTrackFromHeaderlessWigFix {
  my $self = shift;

  #there can only be ONE
  #the one that binds them
  my @files = $self->all_local_files;

  my ($file) = @files;

  if(@files > 1) {
    $self->log('warn', 'In Cadd/Buil more than one local_file specified. Taking first,
      which is ' . $file);
  }

  my $fh = $self->get_read_fh($file);
  
  my %data = ();
  my $wantedChr;
  
  my $singleWantedChrRegex;
  if($self->wantedChr) {
    $singleWantedChrRegex = $self->wantedChr;
    $singleWantedChrRegex = qr/$singleWantedChrRegex/;
  }

  my $chr;
  my $featureIdxHref;
  my $reqIdxHref;

  my $count = 0;

  my @positions;
  my @inputData;

  # sparse track should be 1 based
  # we have a method ->zeroBased, but in practice I find it more confusing to use
  my $based = $self->based;

  my $delimiter = $self->delimiter;

  my %results;

  MCE::Loop::init {
    chunk_size => 2e8, #read in chunks of 200MB
    max_workers => 30,
    gather => \&writeToDatabase,
  };

  mce_loop_f {
    my ( $mce, $chunk_ref, $chunk_id ) = @_;

    # storing
    # chr => {
      #pos => {
    #    $self->dbName => [val1, val2, val3]
    #  }
    #}
    my %out;

    #count number of positions recorded for each chr  so that 
    #we can comply with $self->commitEvery
    my %count;

    LINE_LOOP: for my $line (@{$_}) {
      if($singleWantedChrRegex && $line !~ $singleWantedChrRegex) {
        next LINE_LOOP;
      } 

      chomp $line;

      my @sLine = split $delimiter, $line;

      #if no single --chr is specified at run time,
      #check against list of genome_chrs
      if(! $singleWantedChrRegex && ! $self->chrIsWanted( $sLine[0] ) ) {
        next;
      }

      if(! defined $out{ $sLine[0] } ) {
        $out{ $sLine[0] } = {};
        $count{ $sLine[0] } = 0;
      }

      #if this chr has more than $self->commitEvery records, put it in db
      if( $count{ $sLine[0] } == $self->commitEvery ) {
        MCE->gather($self, { $sLine[0] => $out{ $sLine[0] } } );
        $out{ $sLine[0] } = {};
        $count{ $sLine[0] } = 0;
      }

      $out{ $sLine[0] }{ $sLine[1] - $based } = $self->prepareData( [$sLine[2], $sLine[3], $sLine[4]] );
      $count{ $sLine[0] }++;
    }

    # http://www.perlmonks.org/?node_id=1110235
    if(%out) {
      MCE->gather($self, \%out);
    }
  } $fh;

  $self->log('info', 'finished building: ' . $self->name);
}

sub writeToDatabase {
  my ($self, $resultRef) = @_;

  for my $chr (keys %$resultRef) {
    if( %{ $resultRef->{$chr} } ) {
      $self->dbPatchBulk($chr, $resultRef->{$chr} );
    }
  }
}

__PACKAGE__->meta->make_immutable;
1;
