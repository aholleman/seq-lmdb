use 5.10.0;
use strict;
use warnings;

use Carp;
use Getopt::Long;
use File::Spec;
# use Path::Tiny;
use Pod::Usage;
use Type::Params qw/ compile /;
use Types::Standard qw/ :type /;
use Log::Any::Adapter;
use YAML::XS qw/ LoadFile /;

use IO::Socket::INET;

use Cpanel::JSON::XS;

my $name = '127.0.0.1'; #Server IP
my $port = '9003';

my ( $snpfile, $yaml_config, $db_location, $verbose, $help, $out_file, $force,
  $debug );

#
# usage
#
GetOptions(
  'c|config=s'   => \$yaml_config,
  's|snpfile=s'  => \$snpfile,
  'l|location=s' => \$db_location,
  'v|verbose'    => \$verbose,
  'h|help'       => \$help,
  'o|out=s'      => \$out_file,
  'f|force'      => \$force,
  'd|debug'      => \$debug,
);

if ($help) {
  Pod::Usage::pod2usage(1);
  exit;
}

unless ( $yaml_config
  and $db_location
  and $snpfile
  and $out_file )
{
  Pod::Usage::pod2usage();
}

# sanity check
unless ( -d $db_location ) {
  say "ERROR: Expected '$db_location' to be a directory.";
  exit;
}
unless ( -f $snpfile ) {
  say "ERROR: Expected '$snpfile' to be a file.";
  exit;
}
unless ( -f $yaml_config ) {
  say "ERROR: Expected '$yaml_config' to be a file.";
  exit;
}
if ( -f $out_file && !$force ) {
  say "ERROR: '$out_file' already exists. Use '--force' switch to over write it.";
  exit;
}

# get absolute path
$out_file = File::Spec->rel2abs($out_file); # path($out_file)->absolute->stringify;
say "writing annotation data here: $out_file" if $verbose;

# read config file to determine genome name for loging and to check validity of config
my $config_href = LoadFile($yaml_config)
  || die "ERROR: Cannot read YAML file - $yaml_config: $!\n";

# set log file
my $log_name = join '.', 'annotation', $config_href->{genome_name}, 'log';
my $log_file = File::Spec->rel2abs( ".", $log_name );
say "writing log file here: $log_file" if $verbose;
Log::Any::Adapter->set( 'File', $log_file );

my $socket = IO::Socket::INET->new(
  'PeerAddr' => $name,
  'PeerPort' => $port,
  'Proto'    => 'tcp'
) or die "Can't create socket ($!)\n";

my $command_hash_ref = {
  'c' => $yaml_config,
  's' => $snpfile,
  'l' => $db_location,
  'v' => $verbose,
  'h' => $help,
  'o' => $out_file,
  'f' => $force,
  'd' => $debug
};

print "Client sending\n";

my $msg = encode_json($command_hash_ref);
print $socket $msg;
close $socket
  or die "Can't close socket ($!)\n";
