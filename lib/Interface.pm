#!/usr/bin/env perl
use 5.10.0;

package Interface;

use File::Basename;

use Mouse;

use Path::Tiny;
# use Types::Path::Tiny qw/Path File AbsFile AbsPath/;
use Mouse::Util::TypeConstraints;

use namespace::autoclean;

use DDP;

use YAML::XS qw/LoadFile/;


use Getopt::Long::Descriptive;

use Seq;
with 'MouseX::Getopt', 'Seq::Role::Message';

subtype AbsFile => as 'Path::Tiny';
coerce AbsFile => from 'Str' => via { if(! -e $_) {die "File doesn't exist"; }; path($_)->absolute; };

subtype AbsPath => as 'Path::Tiny';
coerce AbsPath => from 'Str' => via { path($_)->absolute; };

subtype AbsDir => as 'Path::Tiny';
coerce AbsDir => from 'Str' => via { path($_)->absolute; };


#without this, Getopt won't konw how to handle AbsFile, AbsPath, and you'll get
#Invalid 'config_file' : File '/mnt/icebreaker/data/home/akotlar/my_projects/seq/1' does not exist
#but it won't understand AbsFile=> and AbsPath=> mappings directly, so below
#we use it's parental inference property 
#http://search.cpan.org/~ether/MouseX-Getopt-0.68/lib/MouseX/Getopt.pm
MouseX::Getopt::OptionTypeMap->add_option_type_to_map(
    'Path::Tiny' => '=s',
);

##########Parameters accepted from command line#################
has snpfile => (
  is        => 'rw',
  isa       => 'AbsFile',
  coerce => 1,
  #handles => {openInputFile => 'open'},
  required      => 1,
  handles => {
    snpfilePath => 'stringify',
  },
  writer => 'setSnpfile',
  metaclass => 'Getopt',
  cmd_aliases   => [qw/input snp i/],
  documentation => qq{Input file path.},
);

has out_file => (
  is          => 'ro',
  isa         => 'AbsPath',
  coerce      => 1,
  required    => 1,
  handles => {
    output_path => 'stringify',
  },
  metaclass => 'Getopt',
  cmd_aliases   => [qw/out output/],
  documentation => qq{Where you want your output.},
);

has temp_dir => (
  is          => 'ro',
  isa         => 'AbsDir',
  coerce      => 1,
  metaclass => 'Getopt',
  cmd_aliases   => [qw/out output/],
  documentation => qq{Where you want to temporarily store your output},
);

has config => (
  is          => 'ro',
  isa         => 'AbsFile',
  coerce      => 1,
  required    => 1,
  handles     => {
    configfilePath => 'stringify',
  },
  metaclass => 'Getopt',
  documentation => qq{Yaml config file path.},
);

has overwrite => (
  is          => 'ro',
  isa         => 'Int',
  default     => 0,
  required    => 0,
  metaclass => 'Getopt',
  documentation => qq{Overwrite existing output file.},
);

has debug => (
  is          => 'ro',
  isa         => 'Num',
  default     => 0,
  required    => 0,
  metaclass   => 'Getopt',
 );


has compress => (
  is => 'ro', 
  isa => 'Bool',
  metaclass   => 'Getopt',
  documentation =>
    qq{Compress the output?},
  default => 0,
);


subtype HashRefJson => as 'HashRef'; #subtype 'HashRefJson', as 'HashRef', where { ref $_ eq 'HASH' };
coerce HashRefJson => from 'Str' => via { from_json $_ };
subtype ArrayRefJson => as 'ArrayRef';
coerce ArrayRefJson => from 'Str' => via { from_json $_ };

has publisher => (
  is => 'ro',
  isa => 'HashRefJson',
  coerce => 1,
  required => 0,
  metaclass   => 'Getopt',
  documentation => 
    qq{Tell Seqant how to send messages to a plugged-in interface 
      (such as a web interface) }
);

has ignore_unknown_chr => (
  is          => 'ro',
  isa         => 'Bool',
  default     => 1,
  required    => 0,
  metaclass   => 'Getopt',
  documentation =>
    qq{Don't quit if we find a non-reference chromosome (like ChrUn)}
);

##################Not set in command line######################

#@public, but not passed by commandl ine
has assembly => (
  is => 'ro',
  isa => 'Str',
  required => 0,
  init_arg => undef,
  lazy => 1,
  builder => '_buildAssembly',
  metaclass => 'NoGetopt',  # do not attempt to capture this param
);

has logPath => (
  metaclass => 'NoGetopt',     # do not attempt to capture this param
  is        => 'rw',
  isa       => 'Str',
  required  => 0,
  init_arg  => undef,
  lazy      => 1,
  builder   => '_buildLogPath',
);

has _annotator => (
  is => 'ro',
  isa => 'Seq',
  handles => {
    annotate => 'annotate_snpfile',
  },
  init_arg => undef,
  lazy => 1,
  builder => '_buildAnnotator',
);

sub _buildLogPath {
  my $self = shift;

  my $config_href = LoadFile( $self->configfilePath )
    || die "ERROR: Cannot read YAML file at " . $self->configfilePath . ": $!\n";

  return join '.', $self->output_path, 'annotation', $self->assembly, 'log';
}

sub _buildAnnotator {
  my $self = shift;

  my $args = {
    config => $self->configfilePath,
    snpfile => $self->snpfilePath,
    out_file => $self->output_path,
    debug => $self->debug,
    ignore_unknown_chr => $self->ignore_unknown_chr,
    overwrite => $self->overwrite,
    logPath => $self->logPath,
    publisher => $self->publisher,
    compress => $self->compress
  };
  
  if($self->temp_dir) {
    $args->{temp_dir} = $self->temp_dir;
  }

  return Seq->new_with_config($args);
}

with 'Interface::Validator';

sub BUILD {
  my $self = shift;
  my $args = shift;

  say "running interface";
  #exit if errors found via this Validator.pm method
  $self->validateState;
  say "past interface";
}

#I wish for a neater way; but can't find method in MouseX::GetOpt to return just these arguments
sub _buildAnnotatorArguments {
  my $self = shift;
  my %args;
  for my $attr ( $self->meta->get_all_attributes ) {
    my $name = $attr->name;
    my $value = $attr->get_value($self);
    next unless $value;
    $args{$name} = $value;
  }

  return \%args;
}

sub _buildAssembly {
  my $self = shift;

  my $config_href = LoadFile($self->configfilePath) || $self->log('error',
    sprintf("ERROR: Cannot read YAML file at %s", $self->configfilePath) 
  );
  
  return $config_href->{assembly};
}
__PACKAGE__->meta->make_immutable;

1;

=item messanger

Contains a hash reference (also accept json representation of hash) that 
tells Seqant how to send data to a plugged interface.

Example: {
      room: jobObj.userID,
      message: {
        publicID: jobObj.publicID,
        data: tData,
      },
    };
=cut


# sub _run {
#   my $self = shift;

#   if ( $self->isProkaryotic ) {
#     my $args = "--vcf " . $self->snpfile . " --gb " . $self->genBankAnnotation;

#     system( $self->_prokAnnotatorPath . " " . $args );
#   }
#   else {
#     my $aInstance = Seq->new( $self->_annotatorArgsHref );
#     $aInstance->annotate_snpfile();
#   }
# }

###optional

# has genBankAnnotation => (
#   metaclass   => 'Getopt',
#   is          => 'ro',
#   isa         => 'Str',
#   cmd_aliases => [qw/gb g gen_bank_annotation/],
#   required    => 0,
#   documentation =>
#     qq{GenBank Annotation file path. Required for prokaryotic annotations. Type Str.},
#   predicate => 'isProkaryotic'
# );


# has serverMode  => (
#   metaclass => 'Getopt',
#   is => 'ro',
#   isa => 'Bool',
#   cmd_aliases => 'qw/s server/',
#   required => 0,
#   default => 0,
#   documentation => qq{Enables persistent server mode}
# );

#private vars

# has _prokAnnotatorPath => (
#   is       => 'ro',
#   isa      => AbsFile,
#   required => 1,
#   init_arg => undef,
#   default  => sub {
#     return path( abs_path(__FILE__) )->absolute('/')
#       ->parent->parent->child('./bin/prokaryotic_annotator/vcf-annotator');
#   }
# );
