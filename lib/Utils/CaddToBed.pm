use 5.10.0;
use strict;
use warnings;

use lib '../';
# Takes a CADD file and makes it into a bed-like file, retaining the property
# That each base has 3 (or 4 for ambiguous) lines
# Only works for tab-delimitd files that have the c
package Utils::CaddToBed;

our $VERSION = '0.001';

use Mouse 2;
use namespace::autoclean;
use Path::Tiny qw/path/;
use Scalar::Utils qw/looks_like_number/;

use DDP;

use Seq::Tracks::Build::LocalFilesPaths;

# _localFilesDir, _decodedConfig, compress, _wantedTrack, _setConfig, and logPath, 
extends 'Utils::Base';

######### Arguments accepted ##############
# Take the CADD file and make it a bed file
has delimiter => (is => 'ro', lazy => 1, default => "\t");

sub go {
  my $self = shift;
  
  my $localFilesHandler = Seq::Tracks::Build::LocalFilesPaths->new();

  my $localFiles = $localFilesHandler->makeAbsolutePaths($self->_decodedConfig->{files_dir},
    $self->_wantedTrack->{name}, $self->_wantedTrack->{local_files});

  if (!$localFiles || @$localFiles != 1) {
    $self->log('fatal', "CaddToBed expects a single cadd source file");
  }

  my %wantedChrs = map { $_ => 1 } @{ $self->_decodedConfig->{chromosomes} };

  my ($err, $outPath) = $self->convert($localFiles->[0], \%wantedChrs);

  if($err) {
    $self->log('fatal', "CaddToBed didn't finish because $err");
    return;
  }

  $self->_wantedTrack->{local_files} = [$outPath];
  
  $self->_wantedTrack->{caddToBed_date} = $self->_dateOfRun;

  $self->_backupAndWriteConfig();
}

#@returns (<Str> $err, <Str> $outPath)
sub convert {
  my ($self, $inFilePath, $wantedChrs) = @_;
  
  # Store output handles by chromosome, so we can write even if input file
  # out of order
  my %outFhs;
  my %skippedBecauseExists;
  my @outPaths;

  my $inFh = $self->get_read_fh($inFilePath);

  my $versionLine = <$inFh>;
  chomp $versionLine;

  my $headerLine = <$inFh>;
  chomp $headerLine;

  say "headerLine is";
  p $headerLine;

  my @headerFields = split($self->delimiter, $headerLine);

  # CADD seems to be 1-based
  my $based = 1;

  my $chrIdx = 0;
  my $posIdx = 1;
  my $refIdx = 2;
  my $altIdx = 3;
  my $phredIdx = 5;

  p $inFilePath;

  my $outPathBase = substr($inFilePath, 0, rindex($inFilePath, '.') );
  my $outExt = '.bed';

  my $isCompressed;

  if($inFilePath =~ /\.gz$/) {
    $isCompressed = 1;
  } elsif($self->compress) {
    $isCompressed = 1;
  }

  $outExt .= ( $isCompressed ? '.gz' : substr($inFilePath, rindex($inFilePath, '.') ) );

  my $outPath = "$outPathBase$outExt";

  if(-e $outPath && !$self->overwrite) {
    my $err = "File $outPath exists, and overwrite is not set";
    $self->log('error', "File $outPath exists, and overwrite is not set");
    return $err;
  }

  my $outFh = $self->get_write_fh($outPath);

  say $outFh $versionLine;
  say $outFh join($self->delimiter, 'chrom', 'chromStart', 'chromEnd',
    @headerFields[2 .. $#headerFields]);

  my %lastLocator;
  my %lastLocatorData;

  while(<$inFh>) {
    chomp;

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

    if($chrIdPart eq 'MT') {
      $chrIdPart = 'M';
    }

    my $chr = "chr$chrIdPart";

    if(!exists $wantedChrs->{$chr}) {
      $self->log('warn', "Chromosome $chr not recognized as one of our wanted chromosomes (from $chrIdPart)");
      next;
    }

    if(!looks_like_number($line[$posIdx])) {
      my $err = "Position doesn't look like a number: $line[$posIdx]";

      $self->log('error', $err);
      return $err;
    }

    if(!looks_like_number($line[$phredIdx])) {
      my $err = "PHRED doesn't look like a number: $line[$phredIdx]";

      $self->log('error', $err);
      return $err;
    }

    if($line[$refIdx] !~ /A|C|T|G/)) {
      $self->log('warn', "Ref doesn't look like A|C|T|G: $line[$refIdx]");
      next;;
    }

    if($line[$altIdx] !~ /A|C|T|G/)) {
      $self->log('warn', "Alt doesn't look like A|C|T|G: $line[$altIdx]");
      next;
    }

    my $pos = line[$posIdx];

    my $locator = "$chr\_$pos";
    if(!$lastLocator{$locator}) {
      my $ref = $lastLocatorData{ref};

      if($lastLocatorData{alt}{$ref}) {
        my $lastLocator = (keys %lastLocator);

        my $err = "Last position contains reference base as alt: $lastLocator";
        $self->log('error', $err);
        return $err;
      }
    }

    #line[1] is start
    my $end = $line[$posIdx];
    my $start = $end - $based;
    
    say $outFh join($self->delimiter, $chr, $start, $end, @line[2 .. $#line]);
  }

  return (undef, $outPath);
}

__PACKAGE__->meta->make_immutable;
1;
