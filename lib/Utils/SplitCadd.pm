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

# _localFilesDir, _decodedConfig, compress, _wantedTrack, _setConfig, and logPath, 
extends 'Utils::Base';

########## Arguments accepted ##############
# Take the CADD file and make it a bed file
has to_bed => (is => 'ro', isa => 'Bool', lazy => 1, default => 0);

has delimiter => (is => 'ro', lazy => 1, default => "\t");

sub BUILD {
  my $self = shift;

  if (@{ $self->_wantedTrack->{local_files} } != 1) {
    $self->log('fatal', "Can only split files if track has 1 local_file");
  }
}

sub split {
  my $self = shift;

  my %allChrs = map { $_ => 1 } @{ $self->_decodedConfig->{chromosomes} };

  my $filePath = $self->_wantedTrack->{local_files}[0];

  my $outPathBase = substr($filePath, 0, rindex($filePath, '.') );
  
  my $fullPath = path($self->_localFilesDir)->child($filePath)->stringify;

  my $outExt;

  if($self->to_bed) {
    $outExt .= ".bed";
  }

  $outExt .= $outExt . $self->compress ? '.gz' : substr($filePath, rindex($filePath, '.') );

  # Store output handles by chromosome, so we can write even if input file
  # out of order
  my %outFhs;
  my %skippedBecauseExists;

  # We'll update this list of files in the config file
  $self->_wantedTrack->{local_files} = [];

  my $fh = $self->get_read_fh($fullPath);

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

    if(!exists $allChrs{$chr}) {
      $self->log('warn', "Chromosome $chr not recognized (from $chrIdPart)");
      next;
    }

    if(exists $skippedBecauseExists{$chr}) {
      next;
    }

    my $fh = $outFhs{$chr};

    if(!$fh) {
      my $outPathChrBase = "$outPathBase.$chr$outExt";

      my $outPath = path($self->_localFilesDir)->child($outPathChrBase)->stringify;

      if(-e $outPath && !$self->overwrite) {
        $self->log('warn', "File $outPath exists, and overwrite is not set");
        $skippedBecauseExists{$chr} = 1;
        next;
      }

      $outFhs{$chr} = $self->get_write_fh($outPath);

      $fh = $outFhs{$chr};

      say $fh $versionLine;
      say $fh join($self->delimiter, 'chrom', 'chromEnd', 'chromEnd', @headerFields[2 .. $#headerFields]);
    }
    

    if($self->to_bed) {
      my $start = $line[1] - $based;
      my $end = $start + 1;
      say $fh join($self->delimiter, $chr, $start, $end, @line[2 .. $#line]);
      next;
    }
    

    if($allChrs{$chr}) {
      say $fh $_;
    }
  }

  $self->_backupAndWriteConfig();
}

__PACKAGE__->meta->make_immutable;
1;
