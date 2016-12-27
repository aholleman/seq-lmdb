use 5.10.0;
use strict;
use warnings;

package Seq::Definition;
use Mouse::Role 2;
use Types::Path::Tiny qw/AbsPath AbsFile AbsDir/;

#Defines a few keys common to seq methods

has chromField => (is => 'ro', default => 'chrom');
has posField => (is => 'ro', default => 'pos');
has typeField => (is => 'ro', default => 'type');
has discordantField => (is => 'ro', default => 'discordant');
has altField => (is => 'ro', default => 'alt');
has heterozygotesField => (is => 'ro', default => 'heterozygotes');
has homozygotesField => (is => 'ro', default => 'homozygotes');

# output_file_base contains the absolute path to a file base name
# Ex: /dir/child/BaseName ; BaseName is appended with .annotated.tab , .annotated-log.txt, etc
# for the various outputs
has output_file_base => ( is => 'ro', isa => AbsPath, coerce => 1, required => 1, 
  handles => { outputFileBasePath => 'stringify' });

#Don't handle coercion to AbsDir here,
has temp_dir => ( is => 'ro', isa => AbsDir, coerce => 1, handles => { tempPath => 'stringify' });

# Tracks configuration hash. This usually comes from a YAML config file (i.e hg38.yml)
has tracks => (is => 'ro', required => 1);

# The statistics configuration options, usually defined in a YAML config file
has statistics => (is => 'ro');

# Users may not need statistics
has run_statistics => (is => 'ro', isa => 'Bool', default => 1);

# Do we want to compress?
has compress => (is => 'ro', default => 1);

# We may not want to delete our temp files
has delete_temp => (is => 'ro', default => 1);

############################ Private ###################################
#@ params
# <Object> filePaths @params:
  # <String> compressed : the name of the compressed folder holding annotation, stats, etc (only if $self->compress)
  # <String> converted : the name of the converted folder
  # <String> annnotation : the name of the annotation file
  # <String> log : the name of the log file
  # <Object> stats : the { statType => statFileName } object
# Allows us to use all to to extract just the file we're interested from the compressed tarball
has outputFilesInfo => (is => 'ro', init_arg => undef, default => sub{ {} } );

no Mouse::Role;
1;