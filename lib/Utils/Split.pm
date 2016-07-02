use 5.10.0;
use strict;
use warnings;

use lib '../';
# Takes a yaml file that defines one local file, and splits it on chromosome
# Only works for tab-delimitd files that have the c
package Utils::Split;

our $VERSION = '0.001';

use Moose 2;

use namespace::autoclean;
use Path::Tiny qw/path/;
use YAML::XS qw/ Dump /;

use Parallel::ForkManager;
use DDP;

# _localFilesDir, _decodedConfig, compress, _wantedTrack, _setConfig, and logPath, 
extends 'Utils::Base';

########## Arguments accepted ##############
has header_rows => ( is => 'ro', isa => 'Int', required => 1);

sub BUILD {
  my $self = shift;

  if (@{ $self->_wantedTrack->{local_files} } != 1) {
    $self->log('fatal', "Can only split files if track has 1 local_file");
  }
}

sub split {
  my $self = shift;

  my @allChrs = $self->_decodedConfig->{chromosomes};

  my $pm = Parallel::ForkManager->new(scalar @allChrs);

  my $filePath = $self->_wantedTrack->{local_files}[0];

  my $outPathBase = substr($filePath, 0, rindex($filePath, '.') );
  
  my $fullPath = path($self->_localFilesDir)->child($filePath)->stringify;

  my $ext = $self->compress ? '.gz' : substr($filePath, rindex($filePath, '.') );

  # We'll update this list of files
  $self->_wantedTrack->{local_files} = [];

  for my $chr (@allChrs) {
    my $outPathChrBase = "$outPathBase.$chr$ext";

    $pm->start([$chr, $outPathChrBase]) and next;
      my $outPath = path($self->_localFilesDir)->child($outPathChrBase)->stringify;

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
      push @{ $self->_wantedTrack->{local_files} }, $dataAref->[1];
      $self->log('info', "Finished splitting $filePath on $dataAref->[0]");
      return;
    }

    $self->log('fatal', "Failed to split $filePath on $dataAref->[0], exit code: $exitCode");
  });

  $pm->wait_all_children;

  $self->_backupAndWriteConfig();
}

__PACKAGE__->meta->make_immutable;
1;
