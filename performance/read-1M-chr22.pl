use 5.10.0;
use warnings;
use strict;

package MockAnnotationClass;
use lib './lib';
use Moose;
extends 'Seq::Base';
with 'Seq::Role::DBManager';

#__PACKAGE__->meta->
1;

use DDP;

my $tracks = MockAnnotationClass->new_with_config(
  { configfile =>'./config/hg19.lmdb.yml'}
);

my $dataAref = $tracks->dbRead('chr22', [20e6..21e6], 1);

my @out;
my @trackGetters = $tracks->getAllTrackGetters();
my %singleLine;
foreach (@$dataAref)  {
  #This is a few seconds slower, maybe becuase of extra assignments needed for $data
  #push @out, { map { $_->name => $_->get($data, 'chr22') } @trackGetters };

  #than this
  for my $track (@trackGetters) {
    $singleLine{$track->name} = $track->get($_, 'chr22');
  }
  push @out, \%singleLine;
}