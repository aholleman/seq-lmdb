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
use Utils::LiftOverCadd;
use Utils::SortCadd;
use Utils::RenameTrack;

use DDP;

use Seq::Build;

my (
  $yaml_config, $wantedName, $sort, $renameTrack,
  $help,        $liftOver, $liftOver_path, $liftOver_chain_path, 
  $debug,       $overwrite, $fetch, $split, $compress, $toBed,
  $renameTrackTo, $verbose, $dryRunInsertions,
);

# usage
GetOptions(
  'c|config=s'   => \$yaml_config,
  'n|name=s'     => \$wantedName,
  'h|help'       => \$help,
  'd|debug=i'      => \$debug,
  'o|overwrite'  => \$overwrite,
  'fetch' => \$fetch,
  'splitCadd' => \$split,
  'sortCadd'  => \$sort,
  'renameTrack'  => \$renameTrack,
  'liftOver_cadd' => \$liftOver,
  'compress' => \$compress,
  'to_bed'   => \$toBed,
  'liftOver_path=s' => \$liftOver_path,
  'liftOver_chain_path=s' => \$liftOver_chain_path,
  'rename_to=s' => \$renameTrackTo,
  'verbose=i' => \$verbose,
  'dry_run_insertions' => \$dryRunInsertions,
);

if ( (!$fetch && !$split && !$liftOver && !$sort && !$renameTrack) || $help) {
  say $renameTrack;
  Pod::Usage::pod2usage(1);
  exit;
}

unless ($yaml_config) {
  Pod::Usage::pod2usage();
}

my %options = (
  config       => $yaml_config,
  name         => $wantedName || undef,
  debug        => $debug,
  overwrite    => $overwrite || 0,
  to_bed        => $toBed || 0,
  overwrite    => $overwrite || 0,
  liftOver_path => $liftOver_path || '',
  liftOver_chain_path => $liftOver_chain_path || '',
  rename_track_to => $renameTrackTo,
  verbose => $verbose,
  dry_run_insertions => $dryRunInsertions,
);

if($compress) {
  $options{compress} = $compress;
}

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

if($liftOver) {
  my $liftOver = Utils::LiftOverCadd->new(\%options);
  $liftOver->liftOver();
}

if($sort) {
  my $sorter = Utils::SortCadd->new(\%options);
  $sorter->sort();
}

if($renameTrack) {
  say "renaming";
  my $renamer = Utils::RenameTrack->new(\%options);
  $renamer->go();
}

#say "done: " . $wantedType || $wantedName . $wantedChr ? ' for $wantedChr' : '';


__END__

=head1 NAME

run_utils - Runs items in lib/Utils

=head1 SYNOPSIS

run_utils
  --config <file>
  --compress
  --name
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

=item B<-w>, B<--name>

name: The name of the track in the YAML config file

=back

=head1 AUTHOR

Alex Kotlar

=head1 SEE ALSO

Seq Package

=cut
