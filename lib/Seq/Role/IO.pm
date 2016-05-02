use 5.10.0;
use strict;
use warnings;

package Seq::Role::IO;

our $VERSION = '0.001';

# ABSTRACT: A moose role for all of our file handle needs
# VERSION

=head1 DESCRIPTION

  @role Seq::Role::IO
  #TODO: Check description

  @example with 'Seq::Role::IO'

Used in:
=for :list
* Seq/Build/GeneTrack.pm
* Seq/Build/GenomeSizedTrackStr.pm
* Seq/Build/SnpTrack.pm
* Seq/Build/TxTrack.pm
* Seq/Build.pm
* Seq/Fetch/Sql.pm
* Seq/GenomeBin.pm
* Seq/KCManager.pm
* Seq/Role/ConfigFromFile.pm
* Seq

Extended by: None

=cut

use Moose::Role;

use Carp qw/ confess /;
use PerlIO::utf8_strict;
use IO::File;
use IO::Compress::Gzip qw/ $GzipError /;
use IO::Uncompress::AnyUncompress qw/ $AnyUncompressError /;
use Path::Tiny;
use Try::Tiny;
use DDP;

with 'Seq::Role::Message';
# tried various ways of assigning this to an attrib, with the intention that
# one could change the taint checking characters allowed but this is the simpliest
# one that worked; wanted it precompiled to improve the speed of checking
my $taint_check_regex = qr{\A([\+\,\.\-\=\:\/\t\s\w\d]+)\z};

my $delimiter = "\t";
my $endOfLine = "\n";
#@param {Path::Tiny} $file : the Path::Tiny object representing a single input file
#@return file handle

sub get_read_fh {
  my ( $self, $file ) = @_;
  my $fh;
  
  if(ref $file ne 'Path::Tiny' ) {
    $file = path($file)->absolute;
  }

  my $filePath = $file->stringify;

  if (!$file->is_file) {
    return $self->log('error', 'file does not exist for reading: '. $filePath);
  }
  #duck type compressed files
  try {
    $fh = IO::Uncompress::AnyUncompress->new($filePath);
  } catch {
    $self->log('debug', "$filePath probably isn't an archive");
  };
    
  $fh = IO::File->new($filePath, 'r') unless $fh;
  return $self->log('error', "Unable to open file $filePath") unless $fh;

  return $fh;
}

#version based on File::Slurper, advantage is it uses our get_read_fh to support
#compressed files
sub get_file_lines {
  my ($self, $filename) = @_;
  
  my $fh = $self->get_read_fh($filename);
  
  my @buf = <$fh>;
  close $fh;
  chomp @buf;
  return \@buf;
}

# sub get_file_lines {
#   my ( $self, $filePath ) = @_;
#   if ( !-f $filePath ) {
#     confess sprintf( "ERROR: file does not exist for reading: %s", $filePath );
#   }
#   my @lines = path($filePath)->lines; #returns array
# }

#another version, seems slower in practice
#if using this no need to chomp each individual line
# sub slurp_file_lines {
#   my ( $self, $filePath ) = @_;
#   if ( !-f $filePath ) {
#     confess sprintf( "ERROR: file does not exist for reading: %s", $filePath );
#   }
#   return File::Slurper::read_lines( $filePath, 'utf-8', { chomp => 1 } )
#     ; #returns array
# }

sub get_write_fh {
  my ( $class, $file ) = @_;

  confess "\nError: get_fh() expected a filename\n" unless $file;

  my $fh;
  if ( $file =~ m/\.gz\Z/ ) {
    $fh = IO::Compress::Gzip->new($file)
      || confess "gzip failed: $GzipError\n";
  }
  else {
    $fh = IO::File->new( $file, 'w' )
      || confess "\nError: unable to open file ($file) for writing: $!\n";
  }
  return $fh;
}

sub get_write_bin_fh {
  my ( $class, $file ) = @_;

  confess "\nError: get_write_bin_fh() expects a filename\n" unless $file;

  my $fh = IO::File->new( $file, 'w' )
    || confess "\nError: unable to open file ($file) for writing: $!\n";
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

sub splitLine {
  #my ( $class, $line ) = @_;

  return split(/$delimiter/, $_[1]);
}


sub getCleanFields {
  # my ( $self, $line ) = @_;
  # could be called millions of times, so don't copy arguments

  # if(ref $_[1]) {
  #   goto &getCleanFieldsBulk;
  # }

  #https://ideone.com/WVrYxg
  if ( $_[1] =~ m/$taint_check_regex/xm ) {
    my @out;
    foreach ( split($endOfLine, $1) ) {
      push @out, [ split($delimiter, $_) ];
    }
    return @out == 1 ? $out[0] : \@out;
  }
  return;
}

# sub getCleanFieldsBulk {
#   # my ( $self, $lines ) = @_;
#   # could be called millions of times, so don't copy arguments
#   if(!ref $_[0]) {
#     goto &getCleanFields;
#   }

#   my @out;
#   foreach ( @{ $_[0] } ) { #== foreach my $line (@$lines)
#     if ( $_ =~ m/$taint_check_regex/xm ) { #== if ($line =~ ...)
#       push @out, split($delimiter, $1); #$1 == the regex match
#     }
#   }
  
#   return \@out;
# }

no Moose::Role;

1;
