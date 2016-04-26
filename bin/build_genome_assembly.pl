#!/usr/bin/env perl

use 5.10.0;
use strict;
use warnings;

use lib './lib';

use Carp qw/ croak /;
use Getopt::Long;
use Path::Tiny qw/path/;
use Pod::Usage;
use Log::Any::Adapter;
use YAML::XS qw/ LoadFile /;

use DDP;

use Seq::Build;

my (
  $yaml_config, $wantedType,        $wantedName,        $verbose,
  $help,        $wantedChr,        
  $debug,       $overwrite
);

$debug = 0;
# usage
GetOptions(
  'c|config=s'   => \$yaml_config,
  't|type=s'     => \$wantedType,
  #'n|name=s'     => \$wantedName,
  'v|verbose'    => \$verbose,
  'h|help'       => \$help,
  'd|debug=i'      => \$debug,
  'o|overwrite'  => \$overwrite,
  'chr|wanted_chr=s' => \$wantedChr,
);

if ($help) {
  Pod::Usage::pod2usage(1);
  exit;
}

unless ($yaml_config) {
  Pod::Usage::pod2usage();
}

# read config file to determine genome name for log and check validity
my $config_href = LoadFile($yaml_config);

# get absolute path for YAML file and db_location
$yaml_config = path($yaml_config)->absolute->stringify;

#   # set log file
my $log_name = join '.', 'build', $config_href->{genome_name}, $wantedType || 'allTypes',
  $wantedChr || 'allChr', 'log';

my $logPath = path(".")->child($log_name)->absolute->stringify;

my $builder_options_href = {
  configfile   => $yaml_config,
  wantedChr    => $wantedChr,
  wantedType   => $wantedType,
  wantedName   => $wantedName,
  overwrite    => $overwrite,
  debug        => $debug,
  logPath      => $logPath,
};
  

# my $log_file = path(".")->child($log_name)->absolute->stringify;
# Log::Any::Adapter->set( 'File', $log_file );

my $builder = Seq::Build->new_with_config($builder_options_href);

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
