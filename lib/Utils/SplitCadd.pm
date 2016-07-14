use 5.10.0;
use strict;
use warnings;

use lib '../';
# Takes a yaml file that defines one local file, and splits it on chromosome
# Only works for tab-delimitd files that have the c
package Utils::SplitCadd;

our $VERSION = '0.001';

use Mouse 2;
use namespace::autoclean;
use Path::Tiny qw/path/;

use DDP;

use Seq::Tracks::Build::LocalFilesPaths;

# _localFilesDir, _decodedConfig, compress, _wantedTrack, _setConfig, and logPath, 
extends 'Utils::Base';

########## Arguments accepted ##############
# Take the CADD file and make it a bed file
has to_bed => (is => 'ro', isa => 'Bool', lazy => 1, default => 0);

has delimiter => (is => 'ro', lazy => 1, default => "\t");

my $localFilesHandler = Seq::Tracks::Build::LocalFilesPaths->new();
sub BUILD {
  my $self = shift;

  $self->_wantedTrack->{local_files} = $localFilesHandler->makeAbsolutePaths($self->_decodedConfig->{files_dir},
    $self->_wantedTrack->{name}, $self->_wantedTrack->{local_files});

  if (@{ $self->_wantedTrack->{local_files} } != 1) {
    $self->log('fatal', "Can only split files if track has 1 local_file");
  }
}

sub split {
  my $self = shift;

  my %wantedChrs = map { $_ => 1 } @{ $self->_decodedConfig->{chromosomes} };
  
  my $inFilePath = $self->_wantedTrack->{local_files}[0];

  my $outPathBase = substr($inFilePath, 0, rindex($inFilePath, '.') );

  my $outExt;

  if($self->to_bed) {
    $outExt .= ".bed";
  }

  $outExt .= $outExt . $self->compress ? '.gz' : substr($inFilePath,
    rindex($inFilePath, '.') );

  # Store output handles by chromosome, so we can write even if input file
  # out of order
  my %outFhs;
  my %skippedBecauseExists;
  my @outPaths;

  # We'll update this list of files in the config file
  $self->_wantedTrack->{local_files} = [];

  my $fh = $self->get_read_fh($inFilePath);

  my $versionLine = <$fh>;
  chomp $versionLine;

  my $headerLine = <$fh>;
  chomp $headerLine;

  my @headerFields = split($self->delimiter, $headerLine);

  # CADD seems to be 1-based
  my $based = 1;

  while(my $l = $fh->getline() ) {
    chomp $l;

    my @line = split $self->delimiter, $l;

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

    my $chr = "chr$chrIdPart";

    if(!exists $wantedChrs{$chr}) {
      $self->log('warn', "Chromosome $chr not recognized (from $chrIdPart)");
      next;
    }

    if(exists $skippedBecauseExists{$chr}) {
      next;
    }

    my $fh = $outFhs{$chr};

    if(!$fh) {
      my $outPath = "$outPathBase.$chr$outExt";

      if(-e $outPath && !$self->overwrite) {
        $self->log('warn', "File $outPath exists, and overwrite is not set");
        
        $skippedBecauseExists{$chr} = 1;

        push @outPaths, $outPath;

        next;
      }

      $outFhs{$chr} = $self->get_write_fh($outPath);

      push @outPaths, $outPath;

      $fh = $outFhs{$chr};

      say $fh $versionLine;
      say $fh join($self->delimiter, 'chrom', 'chromStart', 'chromEnd',
        @headerFields[2 .. $#headerFields]);
    }
    
    if($self->to_bed) {
      my $start = $line[1] - $based;
      my $end = $start + 1;
      say $fh join($self->delimiter, $chr, $start, $end, @line[2 .. $#line]);
      next;
    }
    
    say $fh $_;
  }

  $self->_wantedTrack->{local_files} = \@outPaths;
  
  $self->_backupAndWriteConfig();
}

__PACKAGE__->meta->make_immutable;
1;
