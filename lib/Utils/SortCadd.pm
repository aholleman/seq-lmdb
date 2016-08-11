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

  my $outExt .= '.organized-by-chr' . ($self->compress ? '.gz' : '.bed');

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
        
        $outFhs{$chr} = $self->get_write_fh($outPath);

        push @outPaths, $outPath;

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

    $pm->start($outPath) and next;
      my ($fileSize, $compressed, $fh) = $self->get_read_fh($outPath);

      my $outExt = '.sorted' . ($compressed ? '.gz' : '.bed');
      my $finalOutPathBase = substr($outPath, 0, rindex($outPath, '.') );

      my $finalOutPath = $finalOutPathBase . $outExt;

      my $status;
      if($compressed) {
        $status = system("( head -n 2 <($gzipPath -d -c $outPath) && tail -n +3 <($gzipPath -d -c $outPath) | sort -k2,2 -n )"
          . " | $gzipPath -c > $finalOutPath; rm $outPath");
      } else {
        $status = system("( head -n 2 $outPath && tail -n +3 $outPath | sort -k2,2 -n ) > $finalOutPath; rm $outPath");
      }

      #update @outPaths to hold the finalOutPath records
      $outPath = $finalOutPath;

    $pm->finish($status);
  }

  $pm->run_on_finish(sub {
    my ($pid, $exitCode, $ident) = @_;

    if($exitCode != 0) {
      return $self->log('fatal', "$ident failed to sort, with exit code $exitCode");
    }
  });

  $pm->wait_all_children();

  $self->_wantedTrack->{local_files} = \@outPaths;
  
  $self->_backupAndWriteConfig();
}

__PACKAGE__->meta->make_immutable;
1;
