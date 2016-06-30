use 5.10.0;
use strict;
use warnings;

package Seq::Fetch::Rsync;

our $VERSION = '0.001';

# ABSTRACT: A class to grab remote rsync data
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Fetch::Rsync>

  @example

Used in: None

Extended in:
=for :list
* Seq::Fetch::Files

=cut

use Moose 2;
use Moose::Util::TypeConstraints;
use MooseX::Types::Path::Tiny qw/AbsFile AbsPath/;

use namespace::autoclean;

has _rsync_cmd  => ( is => 'ro', builder => '_build_rsync_cmd' );
has rsync_path  => ( is => 'ro', isa     => AbsPath, coerce => 1 );
has compress    => ( is => 'ro', isa     => 'Bool', default => 1 );
has dry_run     => ( is => 'ro', isa     => 'Bool', default => 0 );
has verbose     => ( is => 'ro', isa     => 'Bool', default => 0 );
has remote_host => ( is => 'ro', isa     => 'Str', required => 1 );
has remote_dir  => ( is => 'ro', isa     => 'Str', required => 1 );
has remote_file => ( is => 'ro', isa     => 'Str', required => 1 );
has local_dest => (
  is       => 'ro',
  isa      => AbsPath,
  required => 1,
  coerce   => 1,
  handles  => { abs_dest => 'stringify' },
);

sub _build_rsync_cmd {
  my $class = shift;

  my %rsync_loc_for = (
    loc_1 => '/opt/local/bin/rsync',
    loc_2 => '/usr/local/bin/rsync',
    loc_3 => '/usr/bin/rsync'
  );
  for my $sys ( sort keys %rsync_loc_for ) {
    return $rsync_loc_for{$sys} if -f $rsync_loc_for{$sys};
  }

  if ( $class->rsync_path->is_file ) {
    return $class->rsync_path->stringify;
  }
  else {
    my $msg = "Error: cannot find rsync.\n";
    my @loc = map { $rsync_loc_for{$_} } ( keys %rsync_loc_for );
    push @loc, $class->rsync_path->stringify;
    $msg .= join "\n\t", "Looked here:", @loc;
    croak $msg;
  }
}

sub cmd {
  my $self = shift;

  my $bin = $self->_rsync_cmd;
  my $opt = "-a";
  $opt .= "z" if $self->compress;
  $opt .= "n" if $self->dry_run;
  $opt .= "v" if $self->verbose;

  if ( !-d $self->local_dest ) {
    $self->local_dest->mkpath;
  }

  my $remote_file = "rsync://"
    . join( '/', $self->remote_host, $self->remote_dir, $self->remote_file );

  my $cmd = join " ", $bin, $opt, $remote_file, $self->abs_dest;

  return $cmd;

}

__PACKAGE__->meta->make_immutable;

1;
