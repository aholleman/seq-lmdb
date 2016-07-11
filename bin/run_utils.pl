#!/usr/bin/env perl

use 5.10.0;
use strict;
use warnings;

use lib './lib';

use Getopt::Long;
use Path::Tiny qw/path/;
use Pod::Usage;

use Utils::SplitCadd;
use Utils::Fetch;

use DDP;

use Seq::Build;

my (
  $yaml_config, $wantedName,
  $help,         
  $debug,       $overwrite, $fetch, $split, $compress, $toBed
);

# usage
GetOptions(
  'c|config=s'   => \$yaml_config,
  'n|name=s'     => \$wantedName,
  'h|help'       => \$help,
  'd|debug=i'      => \$debug,
  'o|overwrite=i'  => \$overwrite,
  'fetch' => \$fetch,
  'splitCadd' => \$split,
  'compress' => \$compress,
  'to_bed'   => \$toBed,
);

if ( (!$fetch && !$split) || $help) {
  Pod::Usage::pod2usage(1);
  exit;
}

unless ($yaml_config) {
  Pod::Usage::pod2usage();
}

my %options = (
  config       => $yaml_config,
  compress     => $compress || 0,
  name         => $wantedName || undef,
  debug        => $debug,
  overwrite    => $overwrite || 0,
  to_bed        => $toBed || 0,
);

# If user wants to split their local files, needs to happen before we build
# So that the YAML config file has a chance to update
if($split) {
  my $splitter = Utils::SplitCadd->new(\%options);
  $splitter->split();
}

if($fetch) {
  my $fetcher = Utils::Fetch->new(\%options);
  $fetcher->fetch();
}

#say "done: " . $wantedType || $wantedName . $wantedChr ? ' for $wantedChr' : '';


__END__

=head1 NAME

run_utils - Runs items in lib/Utils

=head1 SYNOPSIS

run_utils
  --config <file>
  --compress
  --track_name
  [--debug]

=head1 DESCRIPTION

C<run_utils.pl> Lets you run utility functions in lib/Utils

=head1 OPTIONS

=over 8

=item B<-t>, B<--compress>

Flag to compress output files

=item B<-c>, B<--config>

Config: A YAML genome assembly configuration file that specifies the various
tracks and data associated with the assembly. This is the same file that is
used by the Seq Package to annotate snpfiles.

=item B<-w>, B<--track_name>

track_name: The name of the track in the YAML config file

=back

=head1 AUTHOR

Alex Kotlar

=head1 SEE ALSO

Seq Package

=cut
