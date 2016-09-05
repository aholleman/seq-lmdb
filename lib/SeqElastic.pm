use 5.10.0;
use strict;
use warnings;

package SeqElastic;
use Search::Elasticsearch;

use Path::Tiny;
use Types::Path::Tiny qw/AbsFile AbsPath AbsDir/;
use Mouse 2;

our $VERSION = '0.001';

# ABSTRACT: Index an annotated snpfil

use namespace::autoclean;

use DDP;

use Seq::Output::Delimiters;
use MCE::Loop;

with 'Seq::Role::IO', 'Seq::Role::Message', 'MouseX::Getopt';

has annotated_file_path => (is => 'ro', isa => AbsFile, coerce => 1, required => 1);

has temp_dir => ( is => 'rw', isa => AbsDir, coerce => 1,
  handles => { tempPath => 'stringify' });

has publisher => (is => 'ro');

has logPath => (is => 'ro', isa => AbsPath, coerce => 1);

has debug => (is => 'ro');

has verbose => (is => 'ro');

# Probably the user id
has index_name => (is => 'ro', required => 1);

# Probably the job id
has type_name => (is => 'ro', required => 1);

has dry_run_insertions => (is => 'ro');

has commit_every => (is => 'ro', default => 5000);

sub go {
  my $self = shift; $self->log( 'info', 'Beginning indexing' );

  (my $err, undef, my $fh) = $self->get_read_fh($self->annotated_file_path);

  if($err) {
    $self->_errorWithCleanup($!);
    return ($!, undef);
  }
  
  my $fieldSeparator = $self->delimiter;

  my $taint_check_regex = $self->taint_check_regex; 

  my $firstLine = <$fh>;

  chomp $firstLine;
  
  my @paths;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    @paths = split $fieldSeparator, $1;
  } else {
    return ("First line of input file has illegal characters", undef);
  }

  for (my $i = 0; $i < @paths; $i++) {
    if( index($paths[$i], '.') > -1 ) {
      $paths[$i] = [ split(/\./, $paths[$i]) ];
    }
  }

  my $delimiters = Seq::Output::Delimiters->new();
  my $primaryDelimiter = $delimiters->primaryDelimiter;
  my $secondaryDelimiter = $delimiters->secondaryDelimiter;

  # Todo implement tain check; default taint check doesn't work for annotated files
  $taint_check_regex = qr/./;

  my $commitEvery = $self->commit_every;

  MCE::Loop::init {
    max_workers => 8, use_slurpio => 1, #Disable on shared storage: parallel_io => 1,
    chunk_size => 8192,
  };

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    my @lines;

    my $es = Search::Elasticsearch->new(nodes => [
      '172.31.62.32:9200',
    ]);

    my $bulk = $es->bulk_helper(
      index       => $self->index_name,
      type        => $self->type_name,
      max_count   => $self->commit_every,
      max_size    => 10e6,
      on_error    => sub {
        my ($action,$response,$i) = @_;
        $self->log('error', "Couldn't index: $action ; $response ; $i");
      },           # optional
      on_conflict => sub {
        my ($action,$response,$i,$version) = @_;
        $self->log('error', "Index conflict: $action ; $response ; $i ; $version");
      },           # optional
    );

    open my $MEM_FH, '<', $slurp_ref; binmode $MEM_FH, ':raw';

    my @indexed;
    while ( my $line = $MEM_FH->getline() ) {
      if (! $line =~ /$taint_check_regex/) {
        next;
      }
      chomp $line;

      my @fields = split $fieldSeparator, $line;

      my %rowDocument;
      my $colIdx = 0;
      for my $field (@fields) {
        if( index($field, $secondaryDelimiter) > -1 ) {
          
          my %uniq;
          my @array;

          # | literally is an error; truncates the entire pattern
          # /\$secondaryDelimiter/ doesn't work, neither does \\$secondaryDelimiter
          for my $fieldValue ( split("\\$secondaryDelimiter", $field) ) {
            if ($fieldValue eq 'NA') {
              next;
            }

            if(!defined $uniq{$fieldValue}) {
              push @array, $fieldValue;

              $uniq{$fieldValue} = 1;
            }
          }

          # Field may be undef
          $field = @array > 1 ? \@array : $array[0];
        }

        foreach (ref $field ? @$field : $field) {
          if( index($_, $primaryDelimiter) > -1 ) {
            my %uniq;
            my @array;

            for my $fieldValue ( split("\\$primaryDelimiter", $_) ) {
              if ($fieldValue eq 'NA') {
                next;
              }

              if(!defined $uniq{$fieldValue}) {
                push @array, $fieldValue;

                $uniq{$fieldValue} = 1;
              }
            }

            # This could lead to a nested array where some of the values are undef
            # I don't consider it big enough a deal to worry about
            $_ = @array > 1 ? \@array : $array[0];
          }
        }

        my $pathAref = $paths[$colIdx];

        if(!defined $field || $field eq 'NA') {
          # Don't waste index space on NA's; missing data is implied by lack of
          # data in the document
          $colIdx++;
          next;
        }

        _populateHashPath(\%rowDocument, [ ref $paths[$colIdx] ? @{ $paths[$colIdx] } : $paths[$colIdx] ], $field);

       push @indexed, \%rowDocument;

       $colIdx++;
      }
    }
    $bulk->create_docs(@indexed);
    $bulk->flush;
  } $fh;

  # my $result = $bulk->flush;

  say "finished indexing";
  $self->log('info', "finished indexing");
}

sub _populateHashPath {
  #my ($hashRef, $pathAref, $dataForEndOfPath) = @_;
  #     $_[0]  , $_[1]    , $_[2]

  # If $pathAref isn't an Aref, we're done after the first iteration
  if(!ref $_[1]) {
    $_[0]->{$_[1]} = $_[2];
    return;
  }

  my $pathPart = shift @{ $_[1] };

  if(@{ $_[1] }) {
    if(!defined $_[0]->{$pathPart}) {
      $_[0]->{$pathPart} = {};
    }

    $_[0] = $_[0]->{$pathPart};
    # We have sutff left, so recurse another layer
    goto &_populateHashPath;
  }

  $_[0]->{$pathPart} = $_[2];
  
  return;
}

sub BUILDARGS {
  my ($self, $data) = @_;

  if($data->{temp_dir} ) {
    # It's a string, convert to path
    if(!ref $data->{temp_dir}) {
      $data->{temp_dir} = path($data->{temp_dir});
    }

    $data->{temp_dir} = $self->makeRandomTempDir($data->{temp_dir});
  }

  $data->{out_file} .= '.annotated.tab';
  $data->{logPath} .= '.annotation.log';
  
  return $data;
};

sub BUILD {
  my $self = shift;

  Seq::Role::Message::initialize();

  # Seq::Role::Message settings
  # We manually set the publisher, logPath, verbosity, and debug, because
  # Seq::Role::Message is meant to be consumed globally, but configured once
  # Treating publisher, logPath, verbose, debug as instance variables
  # would result in having to configure this class in every consuming class
  if($self->publisher) {
    $self->setPublisher($self->publisher);
  }

  if ($self->logPath) {
    $self->setLogPath($self->logPath);
  }

  if($self->verbose) {
    $self->setVerbosity($self->verbose);
  }

  #todo: finisih ;for now we have only one level
  if ( $self->debug) {
    $self->setLogLevel('DEBUG');
  } else {
    $self->setLogLevel('INFO');
  }
}

__PACKAGE__->meta->make_immutable;

1;
