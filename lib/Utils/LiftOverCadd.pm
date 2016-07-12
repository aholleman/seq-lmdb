use 5.10.0;
use strict;
use warnings;

use lib '../';
# Takes a yaml file that defines one local file, and splits it on chromosome
# Only works for tab-delimitd files that have the c
package Utils::LiftOverCadd;

our $VERSION = '0.001';

use Mouse 2;
use namespace::autoclean;
use Types::Path::Tiny qw/AbsFile AbsDir/;
use Path::Tiny qw/path/;

use DDP;
use Parallel::ForkManager;

# _localFilesDir, _decodedConfig, compress, _wantedTrack, _setConfig, and logPath, 
extends 'Utils::Base';

########## Arguments accepted ##############
# Take the CADD file and make it a bed file
has liftOver_path => (is => 'ro', isa => AbsFile, coerce => 1, required => 1);
has liftOver_chain_path => (is => 'ro', isa => AbsFile, coerce => 1, required => 1);

sub liftOver {
  my $self = shift;

  my $liftOverExe = $self->liftOver_path;
  my $chainPath = $self->liftOver_chain_path;
  my $gzip = $self->gzipPath;

  my @allLocalFiles = @{ $self->_wantedTrack->{local_files} };

  # We'll update this list of files in the config file
  $self->_wantedTrack->{local_files} = [];

  my $pm = Parallel::ForkManager->new(scalar @allLocalFiles);

  if(!@allLocalFiles) {
    $self->log('fatal', "No local files found");
  }

  my $baseDir = path($self->_localFilesDir);
  for my $filePath (@allLocalFiles) {
    $pm->start($filePath) and next;
      my $inPath = $baseDir->child($filePath)->stringify;

      my (undef, $isCompressed, $inFh) = $self->get_read_fh($inPath);

      my $inPathPart = $isCompressed ? substr( $inPath, 0, rindex($inPath, ".") )
        : $inPath;
    
      my $unmappedPath = $inPathPart . ".unmapped" . ($self->compress ? '.gz' : '');
      my $liftedPath = $inPathPart . ".mapped" . ($self->compress ? '.gz' : '');

      ################## Write the headers to the output file (prepend) ########
      my $versionLine = <$inFh>;
      my $headerLine = <$inFh>;
      chomp $versionLine;
      chomp $headerLine;

      my $outFh = $self->get_write_fh($liftedPath);
      say $outFh $versionLine;
      say $outFh $headerLine;
      close $outFh;

      ################ Liftover #######################
      # Decompresses
      my $command;
      if(!$isCompressed) {
        $command = "$liftOverExe <(cat $inPath | tail -n +3) $chainPath /dev/stdout $unmappedPath -bedPlus=3 | cat - >> $liftedPath";
      } else {
        $command = "$liftOverExe <($gzip -d -c $inPath | tail -n +3) $chainPath /dev/stdout $unmappedPath -bedPlus=3 | $gzip -c - >> $liftedPath";
      }

      #Doesn't output to $fh for some reason
      #open(my $fh, "-|", `bash -c "$command"`);
      # while(<$fh>) {
      #   say "output is $_";
      # }

      #Can't open and stream, limited shell expressions supported, subprocess is not
      my $exitStatus = system(("bash", "-c", $command));
   
      if($exitStatus != 0) {
        $self->log('fatal', "liftOver command for $filePath failed with $exitStatus");
      }

      push @{$self->_wantedTrack->{local_files}}, $liftedPath;
    $pm->finish(0);
  }

  $pm->run_on_finish(sub{
    my ($pid, $exitCode, $file) = @_;
    if($exitCode != 0) {
      $self->log('fatal', "$file failed to liftOver");
    }
  });

  $pm->wait_all_children;

  $self->_backupAndWriteConfig();
}

__PACKAGE__->meta->make_immutable;
1;
