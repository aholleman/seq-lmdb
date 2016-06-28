use 5.10.0;
use strict;
use warnings;

use lib '../';
# Takes a yaml file that defines one local file, and splits it on chromosome
# Only works for tab-delimitd files that have the c
package Utils::Split;

our $VERSION = '0.001';

use Moose 2;

with 'Seq::Role::IO';
with 'Seq::Role::Message';

use namespace::autoclean;
use Path::Tiny qw/path/;
use YAML::XS qw/ Dump LoadFile /;

use MooseX::Types::Path::Tiny qw/AbsDir/;
use Scalar::Util qw/looks_like_number/;
use List::MoreUtils qw/first_index/;

use Parallel::ForkManager;
use DDP;

############## Public exports ################
has updatedConfig => (
  is => 'ro',
  init_arg => undef,
  writer => '_setConfig',
  reader => 'getUpdatedConfigPath'
);


########## Arguments accepted ##############
has header_rows => ( is => 'ro', isa => 'Int', required => 1);

# The track name that they want to split
has wantedName => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

# The YAML config file
has config => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has logPath => (
  is => 'ro',
  lazy => 1,
  default => '',
);

has debug => (
  is => 'ro',
  lazy => 1,
  default => 0,
);

has compress => (
  is => 'ro',
  lazy => 1,
  default => 0,
);

has messageBase => (is => 'ro', lazy => 1, default => undef);
has publisherAddress => (is => 'ro', lazy => 1, default => undef);

# The YAML file as a hash table
my $decodedConfigHref;
# The track of interest
my $wantedTrackConfigHref;
# What the local_files in the track are relative to
my $filesDir;
# What chromosomes this configuration supports
my $genomeChrsHref;
sub BUILD {
  my $self = shift;

  if($self->messageBase && $self->publisherAddress) {
    $self->setPublisher($self->messageBase, $self->publisherAddress);
  }

  if ($self->logPath) {
    $self->setLogPath($self->logPath);
  }

  #todo: finisih ;for now we have only one level
  if ( $self->debug) {
    $self->setLogLevel('DEBUG');
  } else {
    $self->setLogLevel('INFO');
  }

  # Get the track config
  $decodedConfigHref = LoadFile($self->config);
  # Find the request
  my $trackIndex = first_index {$_->{name} eq $self->wantedName} @{$decodedConfigHref->{tracks} };

  $wantedTrackConfigHref = $decodedConfigHref->{tracks}[$trackIndex];

  if(defined $wantedTrackConfigHref->{local_files} > 1) {
    $self->log('fatal', "Can only split files if track has 1 local_file");
  }

  $filesDir = $decodedConfigHref->{files_dir};

  if(!$filesDir) {
    $self->log('fatal', "Must provide files dir in YAML config");
  }

  my $genomeChrsAref = $decodedConfigHref->{genome_chrs};

  if(!@$genomeChrsAref) {
    $self->log('fatal', "Must provide genome_chrs in YAML config");
  }

  $genomeChrsHref = { map { $_ => 1 } @$genomeChrsAref };
}

sub split {
  my $self = shift;

  my @allChrs = keys %$genomeChrsHref;

  my $pm = Parallel::ForkManager->new(scalar @allChrs);

  my $filePath = $wantedTrackConfigHref->{local_files}[0];

  my $outPathBase = substr($filePath, 0, rindex($filePath, '.') );
  
  my $fullPath = path($filesDir)->child($wantedTrackConfigHref->{name})
    ->child($filePath)->stringify;

  my $ext = $self->compress ? '.gz' : substr($filePath, rindex($filePath, '.') );

  # We'll update this list of files
  $wantedTrackConfigHref->{local_files} = [];

  for my $chr (@allChrs) {
    my $outPathChrBase = "$outPathBase.$chr$ext";

    $pm->start([$chr, $outPathChrBase]) and next;
      my $outPath = path($filesDir)->child($wantedTrackConfigHref->{name})
        ->child($outPathChrBase)->stringify;

      my $outFh = $self->get_write_fh($outPath);

      my $fh = $self->get_read_fh($fullPath);

      while(<$fh>) {
        chomp $_;

        if($. <= $self->header_rows) {
          say $outFh $_;
          next;
        }

        my @line = split $self->delimiter, $_;

        # The part that actually has the id, ex: in chrX "X" is the id
        my $chrIdPart;
        # Get the chromosome
        # It could be stored as a number/single character or "chr"
        # Grab the chr part, and normalize it to our case format (chr)
        if($line[0] =~ /chr/i) {
          $chrIdPart = substr($line[0], 3);
        } else {
          $chrIdPart = $line[0];
        }

        if($chr eq "chr$chrIdPart") {
          say $outFh $_;
        }
      }
      
    $pm->finish(0);
  }

  $pm->run_on_finish( sub {
    my ($pid, $exitCode, $dataAref ) = @_;
    if($exitCode == 0) {
      push @{ $wantedTrackConfigHref->{local_files} }, $dataAref->[1];
      $self->log('info', "Finished splitting $filePath on $dataAref->[0]");
      return;
    }
    $self->log('fatal', "Failed to split $filePath on $dataAref->[0], exit code: $exitCode");
  });

  $pm->wait_all_children;

  # Save a new config object
  my $newConfigPath = substr($self->config, 0, rindex($self->config,'.') ) . '.split'
    . substr($self->config, rindex($self->config,'.') );

  open(my $fh, '>', $newConfigPath);

  say $fh Dump($decodedConfigHref);

  $self->_setConfig($newConfigPath);
}

__PACKAGE__->meta->make_immutable;
1;
