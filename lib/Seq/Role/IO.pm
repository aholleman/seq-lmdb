use 5.10.0;
use strict;
use warnings;
# TODO: Also support reading zipped files (right now only gzip files)
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
use PerlIO::gzip;

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
    # to open with pipe needs something like IPC module to catch stderr
    # open ($fh, '-|', "pigz -d -c $file") or die "not a gzip file";
    open($fh, "<:gzip", $filePath) or die "Not a gzip file";
  } catch {
    open($fh, '<', $filePath);
  };
    
  #open($fh, '<', $filePath) unless $fh;
  return $self->log('fatal', "Unable to open file $filePath") unless $fh;

  return $fh;
}

# not used
#version based on File::Slurper, advantage is it uses our get_read_fh to support
#compressed files
# sub get_file_lines {
#   my ($self, $filename) = @_;
  
#   my $fh = $self->get_read_fh($filename);
  
#   my @buf = <$fh>;
#   close $fh;
#   chomp @buf;
#   return \@buf;
# }

sub get_write_fh {
  my ( $self, $file ) = @_;

  confess "\nError: get_fh() expected a filename\n" unless $file;

  my $fh;
  if ( $file =~ m/\.gz\Z/ ) {
    open($fh, ">:gzip", $file) or die "Couldn't open gzip $file for writing";
  } else {
    open($fh, ">", $file) or die "Couldn't open $file for writing";
  }
  return $fh;
}

sub get_write_bin_fh {
  my ( $self, $file ) = @_;

  if(!$file) {
    confess "\nError: get_write_bin_fh() expects a filename\n";
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
no Moose::Role;

1;
