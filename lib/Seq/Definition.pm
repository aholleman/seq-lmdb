use 5.10.0;
use strict;
use warnings;

package Seq::Definition;
use Mouse::Role 2;
use Path::Tiny;
use DDP;
use Types::Path::Tiny qw/AbsPath AbsFile AbsDir/;
use Mouse::Util::TypeConstraints;

use Seq::Tracks;
use Seq::Statistics;

with 'Seq::Role::IO';
# Note: All init_arg undef methods must be lazy if they rely on arguments that are
# not init_arg => undef, and do not have defaults (aka are required)
######################## Required ##############################

# output_file_base contains the absolute path to a file base name
# Ex: /dir/child/BaseName ; BaseName is appended with .annotated.tab , .annotated-log.txt, etc
# for the various outputs
######################## Required ##############################

# output_file_base contains the absolute path to a file base name
# Ex: /dir/child/BaseName ; BaseName is appended with .annotated.tab , .annotated-log.txt, etc
# for the various outputs
has output_file_base => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1,
  handles => { outDir => 'parent', outBaseName => 'basename' });

############################### Optional #####################################
# String, allowing us to ignore it if not truthy
has temp_dir => (is => 'ro', isa => 'Maybe[Str]');

# Do we want to compress?
has compress => (is => 'ro', default => 1);

# The statistics configuration options, usually defined in a YAML config file
has statistics => (is => 'ro', isa => 'HashRef');

# Users may not need statistics
has run_statistics => (is => 'ro', default => sub {!!$_[0]->statistics});

has chromField => (is => 'ro', default => 'chrom', lazy => 1);
has posField => (is => 'ro', default => 'pos', lazy => 1);
has typeField => (is => 'ro', default => 'type', lazy => 1);
has discordantField => (is => 'ro', default => 'discordant', lazy => 1);
has altField => (is => 'ro', default => 'alt', lazy => 1);
has heterozygotesField => (is => 'ro', default => 'heterozygotes', lazy => 1);
has homozygotesField => (is => 'ro', default => 'homozygotes', lazy => 1);

################ Public Exports ##################
#@ params
# <Object> filePaths @params:
  # <String> compressed : the name of the compressed folder holding annotation, stats, etc (only if $self->compress)
  # <String> converted : the name of the converted folder
  # <String> annnotation : the name of the annotation file
  # <String> log : the name of the log file
  # <Object> stats : the { statType => statFileName } object
# Allows us to use all to to extract just the file we're interested from the compressed tarball
has outputFilesInfo => (is => 'ro', isa => 'HashRef', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;

  my %out;

  $out{log} = $self->logPath;

  # Must be lazy in order to allow "revealing module pattern", with output_file_base below
  my $outBaseName = $self->outBaseName;

  $out{annotation} = $outBaseName . '.annotation.tab';

  # Must be lazy in order to allow "revealing module pattern", with _statisticsRunner below
  if($self->run_statistics) {
    $out{statistics} = {
      json => $self->_statisticsRunner->jsonFilePath,
      tab => $self->_statisticsRunner->tabFilePath,
      qc => $self->_statisticsRunner->qcFilePath,
    };
  }

  if($self->compress) {
    # Seq::Role::IO method
    $out{compressed} = $self->makeTarballName($outBaseName);
  }

  return \%out;
});

############################ Private ###################################
# Must be lazy... Mouse doesn't seem to respect attribute definition order at all times
# Leading to situations where $self->outDir doesn't exist by the time _workingDir
# is created. This can lead to the contents of the current working directory being accidentally compressed
# into $self->outputFilesInfo->{compressed}
has _workingDir => (is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;
  return $self->temp_dir ? Path::Tiny->tempdir(DIR => $self->temp_dir, CLEANUP => 1) : $self->outDir;
});

### Override logPath to use the working directory / output_file_base basename ###
has logPath => (is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;
  return $self->_workingDir->child($self->outBaseName. '.annotation-log.txt')->stringify();
});

# Must be lazy because needs run_statistics and statistics
has _statisticsRunner => (is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;

  my $basePath = $self->_workingDir->child($self->outBaseName)->stringify;
  # Assumes that is run_statistics is specified, $self-statistics exists
  if($self->run_statistics) {
    my %args = (
      altField => $self->altField,
      homozygotesField => $self->homozygotesField,
      heterozygotesField => $self->heterozygotesField,
      outputBasePath => $basePath,
    );

    %args = (%args, %{$self->statistics});

    return Seq::Statistics->new(\%args);
  }

  return undef;
});

sub _moveFilesToOutputDir {
  my $self = shift;

  if($self->compress) {
    my $compressErr = $self->compressDirIntoTarball( $self->_workingDir, $self->outputFilesInfo->{compressed} );

    if($compressErr) {
      return $compressErr;
    }
  }

  if( $self->outDir eq $self->_workingDir) {
    $self->log('debug', "Nothing to move, workingDir equals outDir");
    return 0;
  }

  my $workingDir = $self->_workingDir->stringify;
  my $outDir = $self->outDir->stringify;

  $self->log('info', "Moving output file to EFS or S3");

  my $result = system("mv $workingDir/* $outDir;");

  return $result ? $! : 0;
}

# If we need another way of instantiating workingDir that is less error-prone
# (because of the extreme dependence on laziness)
around 'BUILD' => sub {
  my $orig = shift;
  my $self = shift;

  $self->$orig(@_);
};

no Mouse::Role;
1;