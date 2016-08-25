use 5.10.0;
use strict;
use warnings;

package Seq;

our $VERSION = '0.001';

# ABSTRACT: Annotate a snp file

use Mouse 2;
use namespace::autoclean;

use DDP;

use Seq::Output;
use Seq::Tracks;
use Seq::DBManager;

extends 'Seq::Base';

# Tracks configuration hash
has tracks => (is => 'ro', required => 1);

# We need to read from our database
my $db;

# @param <ArrayRef> : an array of Seq::Tracks::* instances
has trackGetters => (is => 'ro', init_arg => undef, writer => '_setTrackGetters');

sub BUILD {
  my $self = shift;

  # Expects DBManager to have been given a database_dir
  $db = Seq::DBManager->new();
  
  # Set the lmdb database to read only, remove locking
  # We MUST make sure everything is written to the database by this point
  $db->setReadOnly(1);

  $self->_setTrackGetters( Seq::Tracks->new({tracks => $self->tracks, gettersOnly => 1}) );
}

sub annotate_snpfile {
  my $self = shift; $self->log( 'info', 'Beginning annotation' );

  my $queryString = shift;

  $queryString =~ tr/\s*//;

  my $taint_check_regex = $self->taint_check_regex;

  if(! $queryString =~ /$taint_check_regex/ ) {
    return $self->log('info', "Query contains illegal characters");
  }

  my ($chr, $positions) = split(/:/, $queryString);

  if(! defined $self->trackGetters->[0]->chromosomes->{ $chr } ) {
    my $assembly = $self->trackGetters->[0]->assembly;
    return $self->log('info', "Chromosome $chr is not a normal $assembly assembly");
  }

  my $dbData;
  if( index($positions, "-") > -1) {
    my ($start, $stop) = split(/-/, $positions);
    # we expect query string to be 1 based
    $start--;
    $stop--;

    $dbData = $db->dbRead($chr, [ $start .. $stop ]);

    if(!@$dbData) {
      return $self->log('info', "No results found for $queryString");
    }
  } else {
    $dbData = $db->dbRead($chr, --$positions);

    if(!defined $dbData) {
      return $self->log('info', "No results found for $queryString");
    }
  }

  my @out;

  for my $position (ref $dbData ? @$dbData : $dbData) {
    push @out, map { $_->name => $_->get($position) } @{ $self->trackGetters };
  }

  my $headers = Seq::Headers->new();

  my $outputter = Seq::Output::JSON->new({
    outputDataFields => $headers->get(),
  });

  return $outputter->makeOutputString(\@out);
}

__PACKAGE__->meta->make_immutable;

1;
