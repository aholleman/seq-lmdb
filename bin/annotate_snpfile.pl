#!/usr/bin/env perl

use 5.10.0;
use strict;
use warnings;

use Carp;
use Getopt::Long;
use File::Spec;
use Pod::Usage;
use Type::Params qw/ compile /;
use Types::Standard qw/ :type /;
use Log::Any::Adapter;
use YAML::XS qw/ LoadFile /;
use Try::Tiny;

use Data::Dump qw/ dump pp /;

use Seq;

my ( $snpfile, $yaml_config, $verbose, $help, $out_file, $overwrite, $no_skip_chr,
  $debug );

# TODO: read directly from argument_format.json

# usage
GetOptions(
  'c|config=s'  => \$yaml_config,
  's|snpfile=s' => \$snpfile,
  'v|verbose'   => \$verbose,
  'h|help'      => \$help,
  'o|out=s'     => \$out_file,
  'overwrite'   => \$overwrite,
  'no_skip_chr' => \$no_skip_chr,
  'd|debug'     => \$debug,
);

if ($help) {
  Pod::Usage::pod2usage(1);
  exit;
}

unless ( $yaml_config
  and $snpfile
  and $out_file )
{
  Pod::Usage::pod2usage();
}

try {
  # sanity checking
  if ( -f $out_file && !$overwrite ) {
    say "ERROR: '$out_file' already exists. Use '--overwrite' switch to over write it.";
    exit;
  }

  # get absolute path
  $snpfile     = File::Spec->rel2abs($snpfile);
  $out_file    = File::Spec->rel2abs($out_file);
  $yaml_config = File::Spec->rel2abs($yaml_config);
  say "writing annotation data here: $out_file" if $verbose;

  # read config file to determine genome name for loging and to check validity of config
  my $config_href = LoadFile($yaml_config)
    || die "ERROR: Cannot read YAML file - $yaml_config: $!\n";

  say pp($config_href) if $debug;

  # set log file
  my $log_name = join '.', 'annotation', $config_href->{genome_name}, 'log';
  my $log_file = File::Spec->rel2abs( ".", $log_name );
  say "writing log file here: $log_file" if $verbose;
  Log::Any::Adapter->set( 'File', $log_file );

  # create the annotator
  my $annotate_instance = Seq->new(
    {
      file_type         => 'snp_2',
      config_file       => $yaml_config,
      debug             => $debug,
      overwrite         => $overwrite,
      ignore_unkown_chr => ( !$no_skip_chr ),
      out_file          => $out_file,
      snpfile           => $snpfile,
    }
  );
  $annotate_instance->annotate_snpfile;
}
catch {
  say $_;
}
__END__

=head1 NAME

annotate_snpfile - annotates a snpfile using a given genome assembly specified
in a configuration file

=head1 SYNOPSIS

annotate_snpfile.pl --config <assembly config> --snp <snpfile> --out <file_ext>

=head1 DESCRIPTION

C<annotate_snpfile.pl> takes a yaml configuration file and snpfile and gives
the annotations for the sites in the snpfile.

=head1 OPTIONS

=over 8

=item B<-s>, B<--snp>

Snp: snpfile

=item B<-c>, B<--config>

Config: A YAML genome assembly configuration file that specifies the various
tracks and data associated with the assembly. This is the same file that is also
used by the Seq Package to build the binary genome without any alteration.

=item B<-o>, B<--out>

Output directory: This is the output director.

=item B<--overwrite>

Overwrite: Overwrite the annotation file if it exists.

=item B<--no_skip_chr>

No_Skip_Chr: Try to annotate all chromosomes in the snpfile and die if unable
to do so.


=back

=head1 AUTHOR

Thomas Wingo

=head1 SEE ALSO

Seq Package

=cut
