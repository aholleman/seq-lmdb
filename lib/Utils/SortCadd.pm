use 5.10.0;
use strict;
use warnings;

use lib '../';
# Takes a yaml file that defines one local file, and splits it on chromosome
# Only works for tab-delimitd files that have the c
package Utils::SortCadd;

our $VERSION = '0.001';

use Mouse 2;
use namespace::autoclean;
use Path::Tiny qw/path/;

use DDP;

use Seq::Tracks::Build::LocalFilesPaths;
use Parallel::ForkManager;

# _localFilesDir, _decodedConfig, compress, _wantedTrack, _setConfig, and logPath, 
extends 'Utils::Base';

########## Arguments accepted ##############
# Take the CADD file and make it a bed file
has delimiter => (is => 'ro', lazy => 1, default => "\t");

my $localFilesHandler = Seq::Tracks::Build::LocalFilesPaths->new();

sub BUILD {
  my $self = shift;

  $self->_wantedTrack->{local_files} = $localFilesHandler->makeAbsolutePaths($self->_decodedConfig->{files_dir},
    $self->_wantedTrack->{name}, $self->_wantedTrack->{local_files});
}

sub sort {
  my $self = shift;

  my %wantedChrs = map { $_ => 1 } @{ $self->_decodedConfig->{chromosomes} };
    
  # record out paths so that we can unix sort those files
  my @outPaths;
  my %outFhs;

  my $outExtPart = $self->compress ? '.txt.gz' : '.txt';

  my $outExt = '.organized-by-chr' . $outExtPart;

  for my $inFilePath ( @{$self->_wantedTrack->{local_files} } ) {
    my $chrIndex = index($inFilePath, '.chr');

    my $outPathBase;

    if($chrIndex > -1) {
      $outPathBase = substr($inFilePath, 0, $chrIndex );
    } else {
      $outPathBase = substr($inFilePath, 0, rindex($inFilePath, '.') );
    }
    
    # Store output handles by chromosome, so we can write even if input file
    # out of order

    my ($size, $compressed, $readFh) = $self->get_read_fh($inFilePath);

    my $versionLine = <$readFh>;
    my $headerLine = <$readFh>;

    # CADD bed files are 0 based

    while(my $l = $readFh->getline() ) {
      #https://ideone.com/05wEAl
      #Faster than split
      my $chr = substr($l, 0, index($l, $self->delimiter) );

      if(!exists $wantedChrs{$chr}) {
        next;
      }

      my $fh = $outFhs{$chr};

      if(!$fh) {
        my $outPath = "$outPathBase.$chr$outExt";

        say "outPath is $outPath";
        
        push @outPaths, $outPath;

        if(-e $outPath && !$self->overwrite) {
          $self->log('warn', "outPath $outPath exists, skipping $inFilePath because overwrite not set");
          last;
        }

        $outFhs{$chr} = $self->get_write_fh($outPath);

        $fh = $outFhs{$chr};

        print $fh $versionLine;
        print $fh $headerLine;
      }
      
      print $fh $l;
    }
  }
  
  for my $outFh (values %outFhs) {
    close $outFh;
  }

  my $pm = Parallel::ForkManager->new(scalar @outPaths);

  for my $outPath (@outPaths) {
    my $gzipPath = $self->gzipPath;

    my ($fileSize, $compressed, $fh) = $self->get_read_fh($outPath);

    my $outExt = '.sorted' . $outExtPart;

    my $finalOutPathBase = substr($outPath, 0, rindex($outPath, '.') );

    my $finalOutPath = $finalOutPathBase . $outExt;

    my $tempPath = path($finalOutPath)->parent()->stringify;

    say "tempPath is";
    p $tempPath;

    $pm->start($finalOutPath) and next;
      my $command;

      if($compressed) {
        $command = "( head -n 2 <($gzipPath -d -c $outPath) && tail -n +3 <($gzipPath -d -c $outPath) | sort --compress-program $gzipPath -T $tempPath -k2,2 -n ) | $gzipPath -c > $finalOutPath";
      } else {
        $command = "( head -n 2 $outPath && tail -n +3 $outPath | sort --compress-program $gzipPath -T $tempPath -k2,2 -n ) > $finalOutPath";
      }

      my $exitStatus = system(("bash", "-c", $command));

      if($exitStatus == 0) {
        $exitStatus = system("rm $outPath");
      }
    $pm->finish($exitStatus);
  }

  my @finalOutPaths;

  $pm->run_on_finish(sub {
    my ($pid, $exitCode, $finalOutPath) = @_;

    if($exitCode != 0) {
      return $self->log('fatal', "$finalOutPath failed to sort, with exit code $exitCode");
    }
    push @finalOutPaths, $finalOutPath;
  });

  $pm->wait_all_children();

  $self->_wantedTrack->{local_files} = \@finalOutPaths;
  
  $self->_backupAndWriteConfig();
}

__PACKAGE__->meta->make_immutable;
1;
