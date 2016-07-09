use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Build::CompletionMeta;
  
  # Keeps track of track build completion
  # TODO: better error handling, not sure how w/ present LMDB API without perf loss
use Moose 2;
use namespace::autoclean;
use DDP;
#exports dbPatchMeta, dbReadMeta
use Seq::DBManager;

with 'Seq::Role::Message';

has name => ( is => 'ro', isa => 'Str', required => 1 );
has skip_completion_check => ( is => 'rw', required => 1, writer => 'setSkipCompletionCheck');

state $metaKey = 'completed';

my $db = Seq::DBManager->new();

sub okToBuild {
  my ($self, $chr) = @_;

  if($self->isCompleted($chr) ) {
    if(!$self->skip_completion_check) {
      return $self->log('debug', "$chr recorded completed for " . $self->name .
        "skip_completion_check not set, not ok to build $chr " . $self->name . " db");
    }
  }

  $self->log('debug', "Ok to build $chr " . $self->name . " db");

  return 1;
}

#hash of completion status
state $completed;

sub recordCompletion {
  my ($self, $chr) = @_;

  # Note that is $self->delete is set, dbPatchMeta will result in deletion of 
  # the $chr record, ensuring that recordCompletion becomes a deletion operation
  # Except this is more clear, and better log message.
  if($self->skip_completion_check) {
    return $self->log('debug', "Skip completion check set, not recording completion of $chr for ". $self->name);
  }

  # overwrite any existing entry for $chr
  my $err = $db->dbPatchMeta($self->name, $metaKey, { $chr => 1 }, 1 );

  if($err) {
    return $self->log('fatal', $err);
  }

  $completed->{$chr} = 1;

  $self->log('debug', "Recorded completion of $chr (set to 1) for " . $self->name . " db");
};

sub eraseCompletionMeta {
  my ($self, $chr) = @_;
  
  # overwrite any existing entry for $chr
  my $err = $db->dbPatchMeta($self->name, $metaKey, { $chr => 0 }, 1 );

  if($err) {
    return $self->log('fatal', $err);
  }

  $completed->{$chr} = 0;

  $self->log('debug', "Erased completion of $chr (set to 0) for " . $self->name . " db");
};

sub isCompleted {
  my ($self, $chr) = @_;

  if(defined $completed->{$chr} ) {
    return $completed->{$chr};
  }

  my $allCompleted = $self->dbReadMeta($self->name, $metaKey);
  
  if($allCompleted && defined $allCompleted->{$chr} && $allCompleted->{$chr} == 1) {
    $completed->{$chr} = 1;
  } else {
    $completed->{$chr} = 0;
  }
  
  return $completed->{$chr};
};

__PACKAGE__->meta->make_immutable;
1;
