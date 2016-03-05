use 5.10.0;
use strict;
use warnings;

#old GenomeSizedTrackStr
package Seq::Types::Reference;

our $VERSION = '0.001';

# ABSTRACT: Builds a plain text genome used for binary genome creation
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Types::Reference>

  TODO: Add description
  Stores a String representation of a genome, as well as the length of each chromosome in the genome.
  Is a single responsibility class with no public functions.

Used in:
=for :list
* Seq/Build/SparseTrack
* Seq/Build

Extended in: None

=cut

use Moose 2;

use Carp qw/ confess croak /;
use File::Path;
use File::Spec;
use namespace::autoclean;
use YAML::XS qw/ Dump LoadFile /;

extends 'Seq::Config::GenomeSizedTrack';
with 'Seq::Role::IO', 'Seq::Role::Genome';

has db => (
  is => 'ro',
  isa => 'Seq::DBManager',
  handles => {
    get => 'db_get',
    patch => 'db_patch',
    patch_bulk => 'db_patch_bulk',
  },
  builder => '_buildDb',
);

has key_name => (
  is => 'ro',
  lazy => 1,
  default => 'ref',
);

sub _buildDb {
  my $self = shift;

  $self->db
}

# @param {HashRef} $posHref : something that contains a key pertaining to this feature
sub get_base {
  my ($self, $posHref) = @_;

  return $posHref->{$self->key_name};
}

sub build_str_genome {
  my $self = shift;

  $self->_logger->info('starting to build string genome');

  my $genome_file      = $self->genome_str_file;
  my $genome_file_size = -s $genome_file;
  my $genome_str       = '';

  if ( $genome_file_size ) {

    $self->_logger->info('Skipping reading genome');

    my $fh = $self->get_read_fh($genome_file);
    read $fh, $genome_str, $genome_file_size;
  }
  else {
    $self->_logger->info("building genome string");

    # hash to hold temporary chromosome strings
    my %seq_of_chr;

    for my $file ( $self->all_local_files ) {
      unless ( -f $file ) {
        my $msg = "ERROR: cannot find $file";
        $self->_logger->error($msg);
        say $msg;
        exit(1);
      }
      my $in_fh      = $self->get_read_fh($file);
      my $wanted_chr = 0;
      my $chr;
      my $chr_position; # absolute by default, 0 index

      while ( my $line = $in_fh->getline() ) {
        chomp $line;
        $line =~ s/\s+//g;
        if ( $line =~ m/\A>([\w\d]+)/ ) {
          if(%seq_of_chr) {
            $self->db_patch_bulk($chr, \%seq_of_chr);
            %seq_of_chr = ();
            $chr_position = 0;
          }
          $chr = $1;
          if ( grep { /$chr/ } $self->all_genome_chrs ) {
            $wanted_chr = 1;
          }
          else {
            my $msg = "skipping unrecognized chromsome: $chr";
            $self->_logger->warn($msg);
            warn $msg . "\n";
            $wanted_chr = 0;
          }
        } elsif ( $wanted_chr && $line =~ m/(\A[ATCGNatcgn]+)\z/xms ) {
          for my $char (@{split(//, $line) } ) {
            $seq_of_chr{$chr_position} = {
              $self->key_name => $char,
            };
            $chr_position++;
          }
        }

        # warn if a file does not appear to have a vaild chromosome - concern
        #   that it's not in fasta format
        if ( $. == 2 and !$wanted_chr ) {
          my $err_msg = sprintf(
            "WARNING: Found %s in %s but '%s' is not a valid chromsome for %s.
            You might want to ensure %s is a valid fasta file.", $chr, $file, $self->name, $file
          );
          $err_msg =~ s/[\s\n]+/ /xms;
          $self->_logger->info($err_msg);
          warn $err_msg;
        }
      }
      if(%seq_of_chr) {
        $self->db_patch_bulk($chr, \%seq_of_chr);
        %seq_of_chr = ();
      }
    }
  }
  $self->_logger->info('finished building string genome');
  return $genome_str;
}

__PACKAGE__->meta->make_immutable;

1;
