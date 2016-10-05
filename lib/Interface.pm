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
with 'MouseX::Getopt';

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
  cmd_aliases   => [qw/o out out_file/],
  metaclass => 'Getopt',
  documentation => qq{Where you want your output.},
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

has verbose => (
  is          => 'ro',
  isa         => 'Bool',
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

has run_statistics => (
  is => 'ro', 
  isa => 'Int',
  metaclass   => 'Getopt',
  documentation =>
    qq{Create per-sample feature statistics (like transition:transversions)?},
  default => 1,
);

has delete_temp => (
  is => 'ro',
  isa => 'Int',
  documentation =>
    qq{Delete the temporary directory made during annotation},
  default => 1,
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

sub annotate {
  my $self = shift;
  
  my $args = {
    config => $self->configfilePath,
    snpfile => $self->snpfilePath,
    out_file => $self->output_path,
    debug => $self->debug,
    ignore_unknown_chr => $self->ignore_unknown_chr,
    overwrite => $self->overwrite,
    publisher => $self->publisher,
    compress => $self->compress,
    verbose => $self->verbose,
    run_statistics => !!$self->run_statistics,
    delete_temp => !!$self->delete_temp,
  };

  my $annotator = Seq->new_with_config($args);
  $annotator->annotate();
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
