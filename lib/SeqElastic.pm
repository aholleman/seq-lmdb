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
use MCE::Shared;

use Scalar::Util qw/looks_like_number/;

with 'Seq::Role::IO', 'Seq::Role::Message', 'MouseX::Getopt';

# An archive, containing an "annotation" file
has annotatedFilePath => (is => 'ro', isa => AbsFile, coerce => 1,
  writer => '_setAnnotatedFilePath');

has publisher => (is => 'ro');

has logPath => (is => 'ro', isa => AbsPath, coerce => 1);

has debug => (is => 'ro');

has verbose => (is => 'ro');

# Probably the user id
has indexName => (is => 'ro', required => 1);

# The index type; probably the job id
has indexType => (is => 'ro', required => 1);

has dryRunInsertions => (is => 'ro');

has commitEvery => (is => 'ro', default => 5000);

# If inputFileNames provided, inputDir is required
has inputDir => (is => 'ro', isa => AbsDir, coerce => 1);

# The user may have given some header fields already
# If so, this is a re-indexing job, and we will want to append the header fields
has headerFields => (is => 'ro', isa => 'ArrayRef');

# The user may have given some additional files
# We accept only an array of bed file here
# TODO: implement
has addedFiles => (is => 'ro', isa => 'ArrayRef');

# IF the user gives us an annotated file path, we will first index from
# The annotation file wihin that archive
#@ params
# <Object> filePaths @params:
  # <String> compressed : the name of the compressed folder holding annotation, stats, etc (only if $self->compress)
  # <String> converted : the name of the converted folder
  # <String> annnotation : the name of the annotation file
  # <String> log : the name of the log file
  # <Object> stats : the { statType => statFileName } object
# Allows us to use all to to extract just the file we're interested from the compressed tarball
has inputFileNames => (is => 'ro', isa => 'HashRef');


sub go {
  my $self = shift; $self->log( 'info', 'Beginning indexing' );

  my ($filePath, $annotationFileInCompressed) = $self->_getFilePath();

  (my $err, undef, my $fh) = $self->get_read_fh($filePath,, $annotationFileInCompressed);
  
  if($err) {
    #TODO: should we report $err? less informative, but sometimes $! reports bull
    #i.e inappropriate ioctl when actually no issue
    $self->_errorWithCleanup($!);
    return ($!, undef);
  }
  
  my $fieldSeparator = $self->delimiter;

  my $taint_check_regex = $self->taint_check_regex; 

  my $firstLine = <$fh>;

  chomp $firstLine;
  
  my @headerFields;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    @headerFields = split $fieldSeparator, $1;
  } else {
    return ("First line of input file has illegal characters", undef);
  }

  my @paths = @headerFields;
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

  MCE::Loop::init {
    max_workers => 8, use_slurpio => 1, #Disable on shared storage: parallel_io => 1,
    chunk_size => 8192,
    gather => $self->makeLogProgress(),
  };

  my $es = Search::Elasticsearch->new(nodes => [
    '172.31.62.32:9200',
  ]);

  my $m1 = MCE::Mutex->new;
  tie my $abortErr, 'MCE::Shared', '';

  my $bulk = $es->bulk_helper(
    index       => $self->indexName,
    type        => $self->indexType,
    max_count   => $self->commitEvery,
    max_size    => 10e6,
    on_error    => sub {
      my ($action,$response,$i) = @_;
      $self->log('warn', "Index error: $action ; $response ; $i");

      $m1->synchronize(sub{ $abortErr = $err; });
    },           # optional
    on_conflict => sub {
      my ($action,$response,$i,$version) = @_;
      $self->log('warn', "Index conflict: $action ; $response ; $i ; $version");
    },           # optional
  );

  mce_loop_f {
    my ($mce, $slurp_ref, $chunk_id) = @_;

    my @lines;
    
    if($abortErr) {
      $mce->abort();
    }

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

      OUTER: for my $field (@fields) {
        # Don't reference the array, because it will modify it in place
        my $path = ref $paths[$colIdx] ? [ @{$paths[$colIdx]} ] : $paths[$colIdx];
        #Do this before everything else, to make sure we track the column index
        #correctly, even if we skip this field
        $colIdx++;
        
        if( index($field, $secondaryDelimiter) > -1 ) {
          my @array;

          # char | is literally is an error; truncates the entire pattern
          # /\$secondaryDelimiter/ doesn't work, neither does \\$secondaryDelimiter
          INNER: for my $fieldValue ( split("\\$secondaryDelimiter", $field) ) {
            if ($fieldValue eq 'NA') {
              next INNER;
            }

            if(looks_like_number($fieldValue) ) {
              $fieldValue += 0;
            }

            push @array, $fieldValue;
          }

          # Field may be undef
          # Modify the field, to be an array, or a scalar
          if(@array > 1) {
            $field = \@array;
          } elsif(@array == 1) {
            $field = $array[0];
          } else {
            say "Skipping this field because secondary delimiter, and empty array:";
            p $field;

            # Skip because the outer fields are both empty, nothing to see for this field
            next OUTER;
          }
        }

        # The value of $totalField may be the one we got in this
        # cell, or a different value, including by modifications below
        # and the ones made above
        my @totalFieldsAccum;
        for my $innerField (ref $field ? @$field : $field) {
          if( index($innerField, $primaryDelimiter) > -1 ) {
            my @array;

            PRIM_INNER: for my $fieldValue ( split("\\$primaryDelimiter", $innerField) ) {
              if ($fieldValue eq 'NA') {
                next PRIM_INNER;
              }

              if(looks_like_number($fieldValue) ) {
                $fieldValue += 0;
              }

              push @array, $fieldValue;
            }

            # This could lead to a nested array where some of the values are undef
            # I don't consider it big enough a deal to worry about
            if(@array > 1) {
              push @totalFieldsAccum, \@array;
            } elsif(@array == 1) {
              push @totalFieldsAccum, $array[0];
            }
            # Do nothing if @array is empty
          } else {
            if($field ne 'NA') {
              push @totalFieldsAccum, $field;
            }
          }
        }

        my $totalFields;
        if(@totalFieldsAccum > 1) {
          $totalFields = \@totalFieldsAccum;
        } elsif(@totalFieldsAccum == 1) {
          $totalFields = $totalFieldsAccum[0];
        } else {
          next OUTER;
        }

        # We could have had a single, scalar value in the cell
        if(looks_like_number($totalFields) ) {
          $totalFields += 0;
        }

        if($totalFields eq 'NA') {
          say "totalFields is somehow NA";
          p $totalFields;
          p $field;
        }

        # Don't waste index space on NA's; missing data is implied by lack of
        # data in the document
        if(defined $totalFields && $totalFields ne 'NA') {
          _populateHashPath(\%rowDocument, $path, $totalFields);
        }
      }

      push @indexed, \%rowDocument;
    }

    say "indexed is";
    p @indexed;

    $bulk->create_docs(@indexed);
    $bulk->flush;

    MCE->gather(scalar @indexed);
  } $fh;

  MCE::Loop::finish();
  
  if($abortErr) {
    $self->log('warn', $abortErr);

    return ($abortErr, undef, undef);
  }

  # Needed to close some kinds of file handles
  # Doing here for consistency, and the eventuality that we will 
  # modify this with something unexpected

  MCE::Shared::stop();
  $self->log('info', "finished indexing");

  return (undef, \@headerFields);
}

sub makeLogProgress {
  my $self = shift;

  my $total = 0;

  my $hasPublisher = $self->hasPublisher;

  if(!$hasPublisher) {
    # noop
    return sub{};
  }

  return sub {
    #my $progress = shift;
    ##    $_[0] 

    if(defined $_[0]) {

      $total += $_[0];

      $self->publishProgress($total);
      return;
    }
  }
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
  
  if(!$pathPart) {
    say "no path part found";
    p @_;
  }
  
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

sub _getFilePath {
  my $self = shift;

  if($self->inputFileNames && $self->inputDir) {
    # The user wants us to make the annotation_file_path
    if(defined $self->inputFileNames->{compressed}) {
      # The user had compressed this file (see Seq.pm)
      # This is expected to be a tarball, which we will extract, but only
      # to stream the annotation file within the tarball package
      my $path = $self->inputDir->child($self->inputFileNames->{compressed});

      return ($path, $self->inputFileNames->{annotation})
    }

    say "in _getFilePath inputFileNames";
    p $self->inputFileNames;
    p $self->inputDir;

    my $path = $self->inputDir->child($self->inputFileNames->{annotation});

    return ($path, undef);
  }

  return $self->annotatedFilePath;
}

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
  if ($self->debug) {
    $self->setLogLevel('DEBUG');
  } else {
    $self->setLogLevel('INFO');
  }

  if(defined $self->inputFileNames) {
    if(!defined $self->inputDir) {
      $self->log('warn', "If inputFileNames provided, inputDir required");
      return ("If inputFileNames provided, inputDir required", undef);
    }

    if(!defined $self->inputFileNames->{compressed}
    && !defined $self->inputFileNames->{annnotation}  ) {
      $self->log('warn', "annotation key required in inputFileNames when compressed key has a value");
      return ("annotation key required in inputFileNames when compressed key has a value", undef);
    }
  } elsif(!defined $self->annotatedFilePath) {
    $self->log('warn', "if inputFileNames not provided, annotatedFilePath must be passed");
    return ("if inputFileNames not provided, annotatedFilePath must be passed", undef);
  }
}

sub _errorWithCleanup {
  my ($self, $msg) = @_;

  # To send a message to clean up files.
  # TODO: Need somethign better
  #MCE->gather(undef, undef, $msg);
  
  $self->log('warn', $msg);
  return $msg;
}

__PACKAGE__->meta->make_immutable;

1;
