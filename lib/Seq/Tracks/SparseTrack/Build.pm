use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::SparseTrack::Build;

our $VERSION = '0.001';

# ABSTRACT: Base class for sparse track building
# VERSION

=head1 DESCRIPTION

  @class Seq::Build::SparseTrack
  #TODO: Check description
  A Seq::Build package specific class, used to define the disk location of the input

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

use Carp qw/ croak /;
use namespace::autoclean;
use List::Util::XS qw/none first/;
use List::MoreUtils::XS qw/firstidx/;
use Parallel::ForkManager;

extends 'Seq::Tracks::Build';

#TODO: allow people to map these names in YAML, via -blah: chrom -blah2: chromStart
state $chrom = 'chrom';
state $cStart = 'chromStart';
state $cEnd   = 'chromEnd';

my $pm = Parallel::ForkManager->new(8);
sub buildTrack {
  # my ($self) = @_;

  # my $chrPerFile = scalar $self->all_local_files > 1 ? 1 : 0;
  # for my $file ($self->all_local_files) {
  #   $pm->start and next;
  #     my $fh = $self->get_read_fh($file);

  #     my %data = ();
  #     my $wantedChr;
      
  #     my $chr;
  #     my %invFeatureIdx = ();
  #     my %invBedIdx = ();

  #     while (<$fh>) {
  #       chomp $_;
  #       $_ =~ s/^\s+|\s+$//g;

  #       my @fields = split "/t", $_;

  #       if($. == 1) {
  #         for my $field ($self->allRequiredFields) {
  #           my $idx = firstidx {$_ eq $field} @fields;
  #           if($idx) {
  #             $iFieldIdx{$field} = $idx;
  #             next;
  #           }
  #           $self->tee_logger('error', 'Required fields missing in $file');
  #         }
  #       }

  #       $chr = $fields[ $iFieldIdx{$chrom} ];

  #       #this will not work well if chr are significantly out of order
  #       #we could move to building a larger hash of {chr => { pos => data } }
  #       #but would need to check commit limits then on a per-chr basis
  #       #easier to just ask people to give sorted files?
  #       #or could sort ourselves.
  #       if($wantedChr ne $chr) {
  #         $self->dbPatchBulk($wantedChr, \%data);

  #         %data = ();
  #         undef $wantedChr;
  #       }


  #       #could optimize this, skip the Moose method
  #       if(!$self->chrIsWanted($chr) ) {
  #         next;
  #       }

  #       my $pAref;
  #       if( $fields[ $iFieldIdx{$cStart} ] == $fields[ $iFieldIdx{$cEnd} ] ) {
  #         $pAref = [ $fields[ $iFieldIdx{$cStart} ] ];
  #       } else {
  #         $pAref = [ $fields[ $iFieldIdx{$cStart} ] .. $fields[ $iFieldIdx{$cEnd} ] ];
  #       }

  #       for my $pos (@$pAref) {
  #         $data{$pos} = 
  #       }

  #       #TODO: remove
  #       say "pos is $pos" if $self->debug;



  #     }
  # }
}
__PACKAGE__->meta->make_immutable;

1;
