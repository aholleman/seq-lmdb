#!/usr/bin/env perl

use lib './lib';
# use Coro;
use Carp qw/ croak /;
use Getopt::Long;
use Modern::Perl qw/ 2013 /;
use Path::Tiny;
use Pod::Usage;
use Type::Params qw/ compile /;
use Types::Standard qw/ :type /;
use Log::Any::Adapter;
use YAML::XS qw/ LoadFile /;

use DDP;

use Seq::Build;

my ( $yaml_config, $build_type, $db_location, $verbose, $help );

#
# usage
#
GetOptions(
  'c|config=s'   => \$yaml_config,
  'l|location=s' => \$db_location,
  't|type=s'     => \$build_type,
  'v|verbose'    => \$verbose,
  'h|help'       => \$help,
);

if ($help) {
  Pod::Usage::pod2usage(1);
  exit;
}

unless (
      defined $yaml_config
  and defined $db_location
  and $build_type
  and ($build_type eq 'conserv'
    or $build_type eq 'genome'
    or $build_type eq 'transcript_db' )
  )
{
  Pod::Usage::pod2usage();
}

# get absolute path for YAML file and db_location
$yaml_config = path($yaml_config)->absolute->stringify;
$db_location = path($db_location)->absolute->stringify;

if ( -d $db_location ) {
  chdir($db_location) || croak "cannot change to dir: $db_location: $!\n";
}
else {
  croak "expected location of db to be a directory instead got: $db_location\n";
}

# read config file to determine genome name for log and check validity
my $config_href = LoadFile($yaml_config);

say qq{ configfile => $yaml_config, db_dir => $db_location };
my $assembly = Seq::Build->new_with_config( { configfile => $yaml_config } );

if ( $build_type eq 'genome' && $config_href ) {

  # set log file
  my $log_name = join '.', 'build', $config_href->{genome_name}, 'genome', 'log';
  my $log_file = path($db_location)->child($log_name)->absolute->stringify;
  Log::Any::Adapter->set( 'File', $log_file );

  # build encoded genome, gene and snp site databases
  $assembly->build_genome_index;
  say "done encoding genome";
}
elsif ( $build_type eq 'conserv' && $config_href ) {

  # set log file
  my $log_name = join '.', 'build', $config_href->{genome_name}, 'conserv', 'log';
  my $log_file = path($db_location)->child($log_name)->absolute->stringify;
  Log::Any::Adapter->set( 'File', $log_file );

  # build conservation scores
  $assembly->build_conserv_scores_index;
  say "done with building conserv scores";
}
elsif ( $build_type eq 'transcript_db' && $config_href ) {

  # set log file
  my $log_name = join '.', 'build', $config_href->{genome_name}, 'transcript_db',
    'log';
  my $log_file = path($db_location)->child($log_name)->absolute->stringify;
  Log::Any::Adapter->set( 'File', $log_file );

  # build transcript database
  $assembly->build_transcript_db;
  say "done with building transcript sequences";
}

__END__

=head1 NAME

build_genome_assembly - builds a binary genome assembly

=head1 SYNOPSIS

build_genome_assembly
  --config <file>
  --locaiton <path>
  --type <'genome', 'conserv', 'transcript_db'>

=head1 DESCRIPTION

C<build_genome_assembly.pl> takes a yaml configuration file and reads raw genomic data
that has been previously downloaded into the 'raw' folder to create the binary
index of the genome and assocated annotations in the mongodb instance.

=head1 OPTIONS

=over 8

=item B<-t>, B<--type>

Type: Either 'genome' or 'extra' refering to the basic genome plus, snp and gene
tracks, or the conservation scores and transcript db.

=item B<-c>, B<--config>

Config: A YAML genome assembly configuration file that specifies the various
tracks and data associated with the assembly. This is the same file that is
used by the Seq Package to annotate snpfiles.

=item B<-l>, B<--location>

Location: Base location of the raw genomic information used to build the
annotation index.

=back

=head1 AUTHOR

Thomas Wingo

=head1 SEE ALSO

Seq Package

=cut
