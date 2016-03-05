use 5.10.0;
use strict;
use warnings;

#old GenomeSizedTrackStr
package Seq::Tracks::Reference::Build;

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
use Parallel::ForkManager;

use namespace::autoclean;

extends 'Seq::Tracks::Build';
with 'Seq::Role::IO', 'Seq::Role::Genome';

my $pm = Parallel::ForkManager->new(30);
sub buildTrack {
  my $self = shift;

  $self->tee_logger('info', 'starting to build string genome');
  
  $self->tee_logger->info("building genome string");

  # hash to hold temporary chromosome strings
  my %seq_of_chr;

  for my $file ( $self->all_local_files ) {
    unless ( -f $file ) {
      $self->tee_logger('error', "ERROR: cannot find $file");
    }
    my $in_fh      = $self->get_read_fh($file);
    my $wanted_chr = 0;
    my $chr;
    my $chr_position; # absolute by default, 0 index

    while ( my $line = $in_fh->getline() ) {
      chomp $line;
      $line =~ s/\s+//g;
      if ( $line =~ m/\A>([\w\d]+)/ ) { #we found a fasta header
        $chr = $1;

        if($seq_of_chr{chr} ne $chr) {
          $self->_write($seq_of_chr{chr}, $seq_of_chr{data});
          %seq_of_chr = ( chr => $chr, data => {} );
          $chr_position = 0;
        }

        if ( grep { /$chr/ } $self->all_genome_chrs ) {
          $wanted_chr = 1;
        } else {
          $self->tee_logger('warn', "skipping unrecognized chromsome: $chr");
          $wanted_chr = 0;
        }
      } elsif ( $wanted_chr && $line =~ m/(\A[ATCGNatcgn]+)\z/xms ) {
        for my $char (@{split(//, $line) } ) {
          $seq_of_chr{data}->{$chr_position} = $char;
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
        $self->tee_logger('info', $err_msg);
      }
    }

    if( $seq_of_chr{data} ) {
      $self->_write($seq_of_chr{chr}, $seq_of_chr{data});
      %seq_of_chr = ();
    }
  }
  $pm->wait_all_children;

  $self->tee_logger('info', 'finished building string genome');
}

sub _write {
  my $self = shift;
  $pm->start or $self->tee_logger('warn', "couldn't write $_[0] Reference track");
    my ($chr, $data) = @_;
    $self->writeAllFeaturesData( $chr, $data );
  $pm->finish;
}
__PACKAGE__->meta->make_immutable;

1;