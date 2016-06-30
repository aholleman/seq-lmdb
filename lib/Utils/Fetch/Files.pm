use 5.10.0;
use strict;
use warnings;

package Seq::Fetch::Files;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class Seq::Fetch::Files
  This class fetches raw files from remote locations (e.g., UCSC genome browser
  rsync server) that are required to build the genome assembly sepcified in the
  configuration file.

  @example

Used in:
=for :list
* Seq::Fetch

Extended by: None

=cut

use Carp;
use File::Path;
use File::Spec;
#use File::Rsync;

use Moose;
use namespace::autoclean;

use DDP;
use Data::Dump qw/ dump /;

use Seq::Fetch::Rsync;

extends 'Seq::Config::GenomeSizedTrack';

has act   => ( is => 'ro', isa => 'Bool', );
has debug => ( is => 'ro', isa => 'Int', );

sub fetch_files {
  my $self = shift;

  my @fetched_files;

  my $name              = $self->name;
  my $remote_files_aref = $self->remote_files;
  my $local_dir         = $self->genome_raw_dir->child( $self->type );

  # get rsync cmd and opts
  my $rsync_basic_opt = {
    compress => 1,
    dry_run  => !$self->act,
    verbose  => $self->debug
  };

  my @remote_src  = split /\//, $self->remote_dir;
  my $remote_host = $remote_src[0];
  my $remote_dir  = join "/", @remote_src[ 1 .. $#remote_src ];

  # fetch files
  for my $file ( @{$remote_files_aref} ) {
    my $dest_file = $local_dir->child($file);
    my $cmd_href  = {
      remote_host => $remote_host,
      remote_dir  => $remote_dir,
      remote_file => $file,
      local_dest  => $dest_file->parent->absolute->stringify
    };
    push @fetched_files, $dest_file->basename;

    my $rsync = Seq::Fetch::Rsync->new( %$rsync_basic_opt, %$cmd_href );

    my $cmd_txt = $rsync->cmd();

    if ( $self->act ) {
      if ( system($cmd_txt) == 0 ) {
        if ( $self->debug ) {
          $self->_logger->info( "rsync cmd: " . $cmd_txt );
        }
        my $msg =
          sprintf( "Successfully downloaded: '%s'", $dest_file->absolute->stringify );
        $self->_logger->info($msg);
      }
      else {
        my $msg = sprintf( "Error downloading: '%s' with cmd: '%s'",
          $dest_file->absolute->stringify, $cmd_txt );
        $self->_logger->error($msg);
      }
      # stagger requests to be kind to the remote server
      sleep 3;
    }
    elsif ( $self->debug ) {
      $self->_logger->info( "rsync cmd: " . $cmd_txt );
    }
  }
  return \@fetched_files;
}

__PACKAGE__->meta->make_immutable;

1;
