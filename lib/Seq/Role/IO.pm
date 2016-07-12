use 5.10.0;
use strict;
use warnings;
# TODO: Also support reading zipped files (right now only gzip files)
package Seq::Role::IO;

our $VERSION = '0.001';

# ABSTRACT: A moose role for all of our file handle needs
# VERSION

use Mouse::Role;

use PerlIO::utf8_strict;
use PerlIO::gzip;
use File::Which qw/which/;

use Path::Tiny;
use Try::Tiny;
use DDP;

with 'Seq::Role::Message';
# tried various ways of assigning this to an attrib, with the intention that
# one could change the taint checking characters allowed but this is the simpliest
# one that worked; wanted it precompiled to improve the speed of checking
our $taint_check_regex = qr{\A([\+\,\.\-\=\:\/\t\s\w\d/]+)\z};

has taint_check_regex => (
  is => 'ro',
  lazy => 1,
  init_arg => undef,
  default => sub{ $taint_check_regex },
);

has delimiter => (
  is => 'ro',
  lazy => 1,
  default => "\t",
); 

has endOfLineChar => (
  is => 'ro',
  lazy => 1,
  default => "\n",
); 

state $tar = which('tar');
state $gzip = which('pigz') || which('gzip');
$tar = "$tar --use-compress-program=$gzip";

has gzipPath => (is => 'ro', isa => 'Str', init_arg => undef, lazy => 1,
  default => sub {$gzip});

#if we compress the output, the extension we store it with
has _compressExtension => (
  is      => 'ro',
  lazy    => 1,
  default => '.tar.gz',
  init_arg => undef,
);

#@param {Path::Tiny} $file : the Path::Tiny object representing a single input file
#@return file handle

sub get_read_fh {
  my ( $self, $file) = @_;
  my $fh;
  
  if(ref $file ne 'Path::Tiny' ) {
    $file = path($file)->absolute;
  }

  my $filePath = $file->stringify;

  if (!$file->is_file) {
    $self->log('fatal', 'file does not exist for reading: '. $filePath);
  }
  
  #duck type compressed files
  my $compressed = 0;
  try {
    # to open with pipe needs something like IPC module to catch stderr
    # open ($fh, '-|', "pigz -d -c $file") or die "not a gzip file";
    open($fh, "<:gzip", $filePath) or die "Not a gzip file";
    close($fh);

    $compressed = 1;
    #PerlIO::gzip doesn't seem to play nicely with MCE, reads random number of lines
    #and then exits, so use gunzip, standard on linux, and faster
    open ($fh, '-|', "$gzip -d -c $file");
  } catch {
    open($fh, '<:unix', "$filePath");
  };

  #open($fh, '<', $filePath) unless $fh;
  $self->log('fatal', "Unable to open file $filePath") unless $fh;

  my $fileSize = $self->getFileSize($filePath, $compressed);

  return ($fileSize, $compressed, $fh);
}

sub get_write_fh {
  my ( $self, $file ) = @_;

  $self->log('fatal', "get_fh() expected a filename") unless $file;

  my $fh;
  if ( $file =~ m/\.gz\Z/ ) {
    open($fh, "|-", "$gzip -c > $file") or $self->log('fatal', "Couldn't open gzip $file for writing");
  } else {
    open($fh, ">", $file) or die $self->log('fatal', "Couldn't open $file for writing");
  }
  return $fh;
}

sub get_write_bin_fh {
  my ( $self, $file ) = @_;

  if(!$file) {
    $self->log('fatal', "Get_write_bin_fh() expects a filename");
  }

  my $fh = $self->get_write_fh($file);

  binmode $fh;
  return $fh;
}

sub clean_line {
  #my ( $class, $line ) = @_;
  if ( $_[1] =~ m/$taint_check_regex/xm ) {
    return $1;
  }
  return;
}

sub getCleanFields {
  # my ( $self, $line ) = @_;
  #       $_[0]  $_[1]
  # could be called millions of times, so don't copy arguments

  # if(ref $_[1]) {
  #   goto &getCleanFieldsBulk;
  # }

  #https://ideone.com/WVrYxg
  if ( $_[1] =~ m/$taint_check_regex/xm ) {
    my @out;
    foreach ( split($_[0]->endOfLineChar, $1) ) {
      push @out, [ split($_[0]->delimiter, $_) ];
    }
    return @out == 1 ? $out[0] : \@out;
  }
  
  return;
}

sub compressPath {
  my $self = shift;

  if(!$tar) { $self->log( 'fatal', 'No tar program found'); }
  
  #expect a Path::Tiny object or a valid file path
  my $fileObjectOrPath = shift;
  if(!ref $fileObjectOrPath) {
    $fileObjectOrPath = path($fileObjectOrPath);
  }

  my $filePath = $fileObjectOrPath->stringify;

  $self->log( 'info', 'Compressing all output files' );

  if ( !-e $filePath ) {
    return $self->log( 'warn', 'No output files to compress' );
  }

  my $basename = $fileObjectOrPath->basename;
  my $thing = $fileObjectOrPath->parent->stringify;

  my $compressName = substr($basename, 0, rindex($basename, ".") ) . $self->_compressExtension;
  
  my $outcome =
    system(sprintf("cd %s; $tar --exclude '.*' --exclude %s -cf %s %s --remove-files",
      $fileObjectOrPath->parent->stringify,
      $compressName,
      $compressName, #and don't include our new compressed file in our tarball
      "$basename*", #the name of the directory we want to compress
    ) );
    
  if($outcome) {
    $self->log( 'warn', "Zipping failed with $?" )
  }
}

sub getFileSize {
  my ( $self, $file, $compressed ) = @_;

  if($compressed) {
    my @raw = `gzip --list $file`;
    my $size = ( split " ", $raw[1] )[1];
    return $size;
  }
  
  my @raw = stat($file);
  return $raw[8];
}

no Mouse::Role;

1;
