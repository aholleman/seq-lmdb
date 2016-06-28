#!/usr/bin/env perl

use 5.10.0;
use strict;
use warnings;

use lib './lib';
use Carp qw/ croak /;
use Getopt::Long;
use Path::Tiny;
use Pod::Usage;
use Log::Any::Adapter;
use YAML::XS qw/ Dump LoadFile /;

use Seq::Fetch;

my ( $cmd, $yaml_config, $out_ext, $verbose, $help, $act );

my %cmd_2_method = (
  snp   => 'fetch_snp_data',
  gene  => 'fetch_gene_data',
  files => 'fetch_genome_size_data',
);
my %cmd_2_track_type = (
  snp   => 'sparse_tracks',
  gene  => 'sparse_tracks',
  files => 'genome_sized_tracks',
);

# usage
GetOptions(
  'a|act'     => \$act,
  'cmd=s'     => \$cmd,
  'config=s'  => \$yaml_config,
  'o|out=s'   => \$out_ext,
  'h|help'    => \$help,
  'v|verbose' => \$verbose,
);

if ($help) {
  Pod::Usage::pod2usage(1);
  exit;
}

unless ( defined $yaml_config and defined $out_ext and defined $cmd ) {
  Pod::Usage::pod2usage();
}

unless ( exists $cmd_2_method{$cmd} ) {
  say "ERROR: expected to command should be either: snp, gene, files";
  exit(1);
}

# get absolute path for YAML file and db_location
$yaml_config = path($yaml_config)->absolute->stringify;

# read config file to determine genome name for log and check validity
my $config_href = LoadFile($yaml_config);

# incorporate all options for object creation
my $fetch_options_href = {
  configfile => $yaml_config,
  act        => $act,
  debug      => $verbose
};

my $fetch_obj = Seq::Fetch->new_with_config($fetch_options_href);

# set log file
my $log_name = join '.', "fetch_$cmd", $config_href->{genome_name}, 'log';
my $log_file = path(".")->child($log_name)->absolute->stringify;
Log::Any::Adapter->set( 'File', $log_file );

# only need to update the file list if it's a sparse track (i.e., gene or snp)
if ( $cmd eq 'gene' or $cmd eq 'snp' ) {
  # set method
  my $method     = $cmd_2_method{$cmd};
  my $files_href = $fetch_obj->$method;

  # set track type depending on the command
  my $track_type = $cmd_2_track_type{$cmd};

  for my $track_href ( @{ $config_href->{$track_type} } ) {
    my $name = $track_href->{name};
    if ( exists $files_href->{$name} ) {
      $track_href->{local_files} = $files_href->{$name};
      my $msg = "updating file list for '$name' with the following:";
      say "=" x 80;
      say $msg;
      say Dump $track_href->{local_files};
      say "=" x 80;
    }
  }
  say "\n" . "=" x 80;
  say "Updated configuration file written: '$out_ext.yml'";
  say "=" x 80;

  my $out_fh = IO::File->new( "$out_ext.yml", 'w' );
  say {$out_fh} Dump($config_href);
}
else {
  my $method     = $cmd_2_method{$cmd};
  my $files_href = $fetch_obj->$method;
  say "\n" . "=" x 80;
  say "fetched these files:";
  say Dump($files_href) if $verbose;
  say "=" x 80;
}

__END__

=head1 NAME

fetch_assembly_files - fetches files for assembly annotation

=head1 SYNOPSIS

fetch_assembly_files
  --config <file>
  --cmd <either: gene, snp, files>
  --out <output extension for new config file>
  [ --act ]
  [ --verbose ]

=head1 DESCRIPTION

C<fetch_assembly_files.pl> takes a yaml configuration file and fetches the
specified raw genomic data.

=head1 OPTIONS

=over 8

=item B<-a>, B<--act>

Act: Optionally fetches (or performs a dry-run).

=item B<--config>

Config: A YAML genome assembly configuration file that specifies the various
tracks and data associated with the assembly. This is the same file that is
used by the Seq Package to annotate snpfiles.

=item B<--cmd>

Cmd: Either gene, snp, or files. These commands correspond to which data type
or set you want to fetch.

=item B<--out>

Out: output extension for the new configuration file automatically generated 
after fetching sql data (updates the list of local files).

=item B<-v>, B<--verbose>

Verbose: Optionally writes comments to log file.

=back

=head1 AUTHOR

Thomas Wingo

=head1 SEE ALSO

Seq Package

=cut
