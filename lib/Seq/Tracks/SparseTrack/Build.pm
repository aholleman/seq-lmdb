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

#do we really need 'name'

has requiredFields => (
  is      => 'ro',
  isa     => 'ArrayRef',
  traits  => ['Array'],
  init_arg => undef,
  lazy => 1,
  builder => '_buildRequiredFields',
  handles => {
    allRequiredFields => 'elements',
  }
);

#TODO: allow people to map these names in YAML, via -blah: chrom -blah2: chromStart
state $chrom = 'chrom';
state $cStart = 'chromStart';
state $cEnd   = 'chromEnd';
sub _buildRequiredFields {
  my $self = shift;
  state $requiredFields;

  if($requiredFields) {
    return $requiredFields;
  }

  push @$requiredFields, ($chrom, $cStart, $cEnd), @{$self->features};
  return $requiredFields;
}

# sub hasRequiredFields {
#   my ( $self, $headerAref) = @_;

#   #assumes trimmed headerStr;
#   for my $f ($self->requiredFields) {
#     if( none{ $f eq $_ } @$headerAref ) {
#       return;
#     }
#   }
#   return 1;
# }

my $pm = Parallel::ForkManager->new(8);
sub buildTrack {
  my ($self) = @_;

  my $chrPerFile = scalar $self->all_local_files > 1 ? 1 : 0;
  for my $file ($self->all_local_files) {
    $pm->start and next;
      my $fh = $self->get_read_fh($file);

      my %out = ();
      my $pos;
      my $wantedChr;
      
      my $chr;
      my %iFieldIdx = ();

      while (<$fh>) {
        chomp $_;
        $_ =~ s/^\s+|\s+$//g;

        my @fields = split "/t", $_;

        if($. == 1) {
          for my $field ($self->allRequiredFields) {
            my $idx = firstidx {$_ eq $field} @fields;
            if($idx) {
              $iFieldIdx{$field} = $idx;
              next;
            }
            $self->tee_logger('error', 'Required fields missing in $file');
          }
        }

        $chr = $fields[ $iFieldIdx{$chrom} ];

        if( $fields[ $iFieldIdx{$cStart} ] == $fields[ $iFieldIdx{$cEnd} ] ) {
          $pos = [ $fields[ $iFieldIdx{$cStart} ] ];
        } else {
          $pos = [ $fields[ $iFieldIdx{$cStart} ] .. $fields[ $iFieldIdx{$cEnd} ] ];
        }

        #TODO: remove
        say "pos is $pos" if $self->debug;

        if($self->chrIsWanted($chr) ) {

        }
      }
  }
}
__PACKAGE__->meta->make_immutable;

1;
