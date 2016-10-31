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
use YAML::XS qw/LoadFile/;
use Try::Tiny;

with 'Seq::Role::IO', 'Seq::Role::Message', 'MouseX::Getopt';

# An archive, containing an "annotation" file
has annotatedFilePath => (is => 'ro', isa => AbsFile, coerce => 1,
  writer => '_setAnnotatedFilePath');

has config => (is => 'ro', isa=> AbsFile, coerce => 1, required => 1, handles => {
  configPath => 'stringify',
});

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
  
  my $searchConfig = LoadFile($self->configPath);

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

  p @headerFields;
  
  my @paths = @headerFields;
  for (my $i = 0; $i < @paths; $i++) {
    if( index($paths[$i], '.') > -1 ) {
      $paths[$i] = [ split(/\./, $paths[$i]) ];
    }
  }

  my $delimiters = Seq::Output::Delimiters->new();
  my $primaryDelimiter = $delimiters->primaryDelimiter;
  my $secondaryDelimiter = $delimiters->secondaryDelimiter;

  say "secondaryDelimiter is $secondaryDelimiter";

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

  if(!$es->indices->exists(index => $self->indexName) ) {
    $es->indices->create(index => $self->indexName, body => {settings => $searchConfig->{settings}});
  } else {
    $es->indices->close(index => $self->indexName);

    $es->indices->put_settings(
      index => $self->indexName,
      body => $searchConfig->{settings},
    );

    $es->indices->open(index => $self->indexName);
  }

  $es->indices->put_mapping(
    index => $self->indexName,
    type => $self->indexType,
    body => $searchConfig->{mappings},
  );

  my $m1 = MCE::Mutex->new;
  tie my $abortErr, 'MCE::Shared', '';

  my $bulk = $es->bulk_helper(
    index       => $self->indexName,
    type        => $self->indexType,
    max_count   => $self->commitEvery,
    max_size    => 10e6,
    on_error    => sub {
      my ($action, $response, $i) = @_;
      $self->log('warn', "Index error: $action ; $response ; $i");
      p $response;
      $m1->synchronize(sub{ $abortErr = $response} );
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
      say "abort error found";
      $mce->abort();
    }

    open my $MEM_FH, '<', $slurp_ref; binmode $MEM_FH, ':raw';

    my $lineCount;
    my @indexed;
    while ( my $line = $MEM_FH->getline() ) {
      $lineCount++;
      if (! $line =~ /$taint_check_regex/) {
        next;
      }
      chomp $line;

      my @fields = split $fieldSeparator, $line;

      my %rowDocument;
      my $colIdx = 0;
      my $foundWeird = 0;

      # We use Perl's in-place modification / reference of looped-over variables
      # http://ideone.com/HNgMf7
      OUTER: for (my $i = 0; $i < @fields; $i++) {
        my $field = $fields[$i];

        my $hasSecondary = 0;
        if( index($field, $secondaryDelimiter) > -1 ) {
          my @array;
          $hasSecondary = 1;

          # char | is literally is an error; truncates the entire pattern
          # /\$secondaryDelimiter/ doesn't work, neither does \\$secondaryDelimiter
          INNER: for my $fieldValue ( split("\\$secondaryDelimiter", $field) ) {
            if ($fieldValue eq 'NA') {
              next INNER;
            }

            push @array, $fieldValue;
          }

          my @splitField = grep { $_ ne 'NA' } split("\\$secondaryDelimiter", $field);

          # Field may be undef
          # Modify the field, to be an array, or a scalar
          if(@splitField > 1) {
            $field = \@splitField;
          } elsif(@splitField == 1) {
            $field = $splitField[0];
          } else {
            $field = undef;
          }
        }

        for my $innerField (ref $field ? @$field : $field) {
          if( index($innerField, $primaryDelimiter) > -1 ) {

            my @splitField = grep { $_ ne 'NA' } split("\\$primaryDelimiter", $innerField);

            if(@splitField > 1) {
              $innerField = \@splitField;
            } elsif(@splitField == 1) {
              $innerField = $splitField[0];
            } else {
              $innerField = undef;
            }

            # Do nothing if @array is empty
          } elsif($innerField eq 'NA') {
            $innerField = undef;
          }

          # Else don't modify the field
        }

        if(defined $field && $field ne 'NA') {
          _populateHashPath(\%rowDocument, $paths[$i], $field);
        }
      }

      push @indexed, \%rowDocument;
    }

    # say "indexed is";
    # p @indexed;

    $bulk->create_docs(@indexed);
    $bulk->flush;

    MCE->gather(scalar @indexed);
  } $fh;

  MCE::Loop::finish();
  
  # Disabled for now, we have many abort errors 
  # if($abortErr) {
  #   MCE::Shared::stop();
  #   say "Error creating index";
  #   return ("Error creating index, check log", undef, undef);
  # }

  # Needed to close some kinds of file handles
  # Doing here for consistency, and the eventuality that we will 
  # modify this with something unexpected

  $self->log('info', "finished indexing");

  return (undef, \@headerFields, $searchConfig);
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
  my ($hashRef, $pathAref, $dataForEndOfPath) = @_;
  #     $_[0]  , $_[1]    , $_[2]

  if(!ref $pathAref) {
    $hashRef->{$pathAref} = $dataForEndOfPath;
    return $hashRef;
  }

  my $href = $hashRef;
  for (my $i = 0; $i < @$pathAref; $i++) {
    if($i + 1 == @$pathAref) {
      $href->{$pathAref->[$i]} = $dataForEndOfPath;
    } else {
      if(!defined  $href->{$pathAref->[$i]} ) {
        $href->{$pathAref->[$i]} = {};
      }
      
      $href = $href->{$pathAref->[$i]};
    }
  }

  return $href;
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
