use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::ScoreTrack::Build;

our $VERSION = '0.001';

# ABSTRACT: Base class for sparse track building
# VERSION

=head1 DESCRIPTION
  
  @class Seq::Build::SparseTrack
  # Accepts a wig format file. For now, only fixed step is supported
  @example

Used in:
=for :list
*

Extended by:
=for :list
* Seq/Build/GeneTrack.pm
* Seq/Build/TxTrack.pm

=cut

use Moose 2;

use namespace::autoclean;
use Parallel::ForkManager;
use DDP;

extends 'Seq::Tracks::Build';
#We could think about how to meaningfully combine these two
#they're extremely similar
#extends 'Seq::Tracks::Reference::Build';
with 'Seq::Tracks::Build::Interface';
my $pm = Parallel::ForkManager->new(1);
sub buildTrack{
  my $self = shift;

  #TODO: use cursor to read first and last position;
  #compare these to first and last entry in the resulting string
  #if identical, and identical length for that chromosome, 
  #don't do any writing.
  $self->tee_logger('info', "starting to build score track $self->name" );

  my $fStep = 'fixedStep';
  my $vStep = 'variableStep';
  my $headerRegex = qr/^($fStep|$vStep)\s+chrom=(\S+)\s+start=(\d+)\s+step=(\d+)/;
  for my $file ( $self->all_local_files ) {
    unless ( -f $file ) {
      $self->tee_logger('error', "ERROR: cannot find $file");
    }
    my $in_fh      = $self->get_read_fh($file);
    my %seq_of_chr;
    my $wanted_chr = 0;
    my $chr;
    my $chr_position = 0; # absolute by default, 0 index
    #my $count = 0;
    my $step;
    my $stepType;

    while ( <$in_fh> ) {
      chomp $_;
      $_ =~ s/^\s+|\s+$//g; #trim both ends, but not what's in between

      #could do check here for cadd default format
      #for now, let's assume that we put the CADD file into a wigfix format
      if ( $_ =~ m/$headerRegex/ ) { #we found a wigfix
        #say "read $_";
        $stepType = $1;
        $chr = $2;
        my $start = $3;
        $step = $4;

        #this will work better if the wigfix file is sorted by chr
        #not sure what happens if two writers attempt 
        #but I hope the 2nd would wait for the first to finish, instead of just dying
        if(!defined $seq_of_chr{chr} ) {
          %seq_of_chr = ( chr => $chr, data => {} );
        } elsif ($seq_of_chr{chr} ne $chr) {
          $self->_write($seq_of_chr{chr}, $seq_of_chr{data} );
          %seq_of_chr = ( chr => $chr, data => {} );
        }

        $chr_position = $start - 1; #0 index
        #say "chr_position is $chr_position";

        if ( $self->chrIsWanted($chr) ) {
          $wanted_chr = 1;
        } else {
          $self->tee_logger('warn', "skipping unrecognized chromsome: $chr");
          $wanted_chr = 0;
        }
      } elsif ( $wanted_chr ) {
        if($stepType eq $vStep) {
          $self->tee_logger('error', 'variable step not currently supported');
        }
        $chr_position += $step;
        $seq_of_chr{data}->{$chr_position} = $_;

        # $count++;
        # if($count >= $self->commitEvery) {
        #   $count = 0;
        #   say "chr is". $seq_of_chr{chr};
        #   $self->_write($seq_of_chr{chr}, $seq_of_chr{data} );
        #   $seq_of_chr{data} = {};
        # }
      }

      # warn if a file does not appear to have a vaild chromosome - concern
      #   that it's not in fasta format
      if ( $. == 2 and !$wanted_chr ) {
        my $err_msg = sprintf(
          "WARNING: Found %s in %s but it's not a wanted chromsome", 
          $chr, $file
        );
        $err_msg =~ s/[\s\n]+/ /xms;
        $self->tee_logger('info', $err_msg);
      }
    }

    if( $seq_of_chr{chr} ) {
      $self->_write($seq_of_chr{chr}, $seq_of_chr{data} );
      %seq_of_chr = ();
    }
  }
  $pm->wait_all_children;

  $self->tee_logger('info', 'finished building string genome');
};

#Because of linux copy-on-write, this is actually very memory efficient
#however, "top" will show the same initial memory usage between the two processes
#(parent and child), which may seem like a gigantic memory leak
#http://serverfault.com/questions/440115/how-do-you-measure-the-memory-footprint-of-a-set-of-forked-processes
sub _write {
  my $self = shift;
  $pm->start and return; #$self->tee_logger('warn', "couldn't write $_[0] Reference track");
    my ($chr, $dataHref) = @_;
    
    say "entering fork for chr $chr"; #if $self->debug; #TODO: remove
    # say "data is";
    # p $dataHref;
    $self->writeAllData( $chr, $dataHref );
  
    $pm->finish;
}


__PACKAGE__->meta->make_immutable;

1;
