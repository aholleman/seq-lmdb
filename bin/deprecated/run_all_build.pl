#!/usr/bin/env perl
# Name:           run_all_build.pl
# Date Created:   Sun May 17 21:10:27 2015
# Date Modified:  Sun May 17 21:10:27 2015
# By:             TS Wingo
#
# Description:

use 5.10.0;
use strict;
use warnings;

use Carp;
use Cwd;
use Getopt::Long;
use File::Spec;
use Path::Tiny;
use Pod::Usage;
use Log::Any::Adapter;
use YAML::XS qw/ LoadFile /;

# variables
my ( $verbose, $act, $config_file, $out_ext, $build_src );
my $cwd  = cwd();
my @type = qw/ genome conserv transcript_db snp_db gene_db /;

# get options
die "Usage: $0 [-v] [-a] -b <build_assembly script> -c <assembly config>\n"
  unless GetOptions(
  'v|verbose'  => \$verbose,
  'a|act'      => \$act,
  'b|build=s'  => \$build_src,
  'c|config=s' => \$config_file,
  ) and $config_file;
$verbose++ unless $act;

# clean path
$build_src   = path($build_src)->absolute->stringify;
$config_file = path($config_file)->absolute->stringify;

my $config_href = LoadFile($config_file);

my @script_files = ( 'build.sh', 'build_alt.sh' );
my $cmd_fh     = IO::File->new( 'build.sh',     'w' ) or die "build.sh: $!\n";
my $alt_cmd_fh = IO::File->new( 'build_alt.sh', 'w' ) or die "build_alt.sh: $!\n";

# For the parellel build on a single computer
# counter needs to start with 0 to get the first genome string built and written
# for subsequent builds (or we'll have some race problem with writing to the same
# file...
my $i = 0;

for my $type (qw/ gene_db snp_db /) {
  for my $chr ( @{ $config_href->{genome_chrs} } ) {
    my $cmd = qq{$build_src --config $config_file --type $type --wanted_chr $chr};
    $cmd .= " --verbose" if $verbose;
    $cmd .= " --act"     if $act;
    my $file_name = Write_script( $type, $chr, $cmd );
    my $alt_cmd = sprintf( "%s %s",
      path('.')->child($file_name)->absolute->stringify,
      ( $i % 3 == 0 ) ? "" : " &" );
    say {$alt_cmd_fh} $alt_cmd;
    $i++;
    my $log_file = File::Spec->rel2abs("$type.$chr.log");
    my $q_cmd    = qq{qsub -v USER -v PATH -cwd -q lh.q -o $log_file -j y $file_name};
    say {$cmd_fh} $q_cmd;
    push @script_files, $file_name;
  }
}

for my $type (qw/ transcript_db conserv genome/) {
  my $cmd = qq{$build_src --config $config_file --type $type};
  $cmd .= " --verbose" if $verbose;
  $cmd .= " --act"     if $act;
  my $file_name = Write_script( $type, 'genome', $cmd );
  my $alt_cmd = path('.')->child($file_name)->absolute->stringify;
  say {$alt_cmd_fh} $alt_cmd;
  my $log_file = File::Spec->rel2abs("$type.genome.log");
  my $q_cmd    = qq{qsub -v USER -v PATH -cwd -q lh.q -o $log_file -j y $file_name};
  say {$cmd_fh} $q_cmd;
  push @script_files, $file_name;
}

close $cmd_fh;
close $alt_cmd_fh;

# make all scripts executable
my $mode = 0755;
chmod $mode, @script_files;

sub Write_script {
  my ( $type, $chr, $cmd ) = @_;
  my $file_name = "$type.$chr.sh";
  my $out_fh = IO::File->new( $file_name, 'w' );
  say {$out_fh} join "\n", '#!/usr/bin/sh', qq{cd $cwd}, $cmd;
  return $file_name;
}
