#!/usr/bin/env perl

use 5.10.0;
use strict;
use warnings;

use lib './lib';

use Getopt::Long;
use Path::Tiny qw/path/;
use Pod::Usage;

use Utils::Split;

use DDP;

use Seq::Build;

my (
  $yaml_config, $wantedName,
  $help,         
  $debug,       $overwrite, $fetch, $split, $header_rows, $compress
);

# usage
GetOptions(
  'c|config=s'   => \$yaml_config,
  'n|name=s'     => \$wantedName,
  'h|help'       => \$help,
  'd|debug=i'      => \$debug,
  'o|overwrite=i'  => \$overwrite,
  'fetch' => \$fetch,
  'split' => \$split,
  'header_rows=i' => \$header_rows,
  'compress' => \$compress,
);

if ( (!$fetch && !$split) || $help) {
  Pod::Usage::pod2usage(1);
  exit;
}

unless ($yaml_config) {
  Pod::Usage::pod2usage();
}

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();

$year += 1900;

my $logName;
if(!$fetch && !$split) {
  $logName = 'splitandFetch';
} elsif ($split) {
  $logName = 'split';
} elsif ($fetch) {
  $logName = 'fetch';
}

#   # set log file
my $log_name = join '.', $logName, $wantedName,
"$mday\_$mon\_$year\_$hour\:$min\:$sec", 'log';

my $logPath = path(".")->child($log_name)->absolute->stringify;

my %options = (
  config       => $yaml_config,
  compress    => $compress || 0,
  header_rows => $header_rows,
  wantedName   => $wantedName || undef,
  debug        => $debug,
  logPath      => $logPath,
  overwrite    => $overwrite || 0,
);
  
# If user wants to split their local files, needs to happen before we build
# So that the YAML config file has a chance to update
if($split) {
  my $splitter = Utils::Split->new(\%options);
  $splitter->split();

  $options{config} = $splitter->getUpdatedConfigPath();
}

if($fetch) {
  my $fetcher = 1; # TODO: make it!
}

#say "done: " . $wantedType || $wantedName . $wantedChr ? ' for $wantedChr' : '';


__END__

=head1 NAME

build_genome_assembly - builds a binary genome assembly

=head1 SYNOPSIS

build_genome_assembly
  --config <file>
  --type <'genome', 'conserv', 'transcript_db', 'snp_db', 'gene_db'>
  [ --wanted_chr ]

=head1 DESCRIPTION

C<build_genome_assembly.pl> takes a yaml configuration file and reads raw genomic
data that has been previously downloaded into the 'raw' folder to create the binary
index of the genome and assocated annotations in the mongodb instance.

=head1 OPTIONS

=over 8

=item B<-t>, B<--type>

Type: A general command to start building; genome, conserv, transcript_db, gene_db
or snp_db.

=item B<-c>, B<--config>

Config: A YAML genome assembly configuration file that specifies the various
tracks and data associated with the assembly. This is the same file that is
used by the Seq Package to annotate snpfiles.

=item B<-w>, B<--wanted_chr>

Wanted_chr: chromosome to build, if building gene or snp; will build all if not
specified.

=back

=head1 AUTHOR

Thomas Wingo

=head1 SEE ALSO

Seq Package

=cut
