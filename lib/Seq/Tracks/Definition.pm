use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Definition;

our $VERSION = '0.001';

# ABSTRACT: A base class for track classes
# VERSION

use Moose::Role;
use Moose::Util::TypeConstraints; 
use namespace::autoclean;
use Scalar::Util qw/looks_like_number/;
# use Seq::Tracks::ReferenceTrack;
# use Seq::Tracks::GeneTrack;
# use Seq::Tracks::ScoreTrack;
# use Seq::Tracks::SparseTrack;
# use Seq::Tracks::SnpTrack;
# use Seq::Tracks::RegionTrack;

# use Seq::Tracks::ReferenceTrack::Build;
# use Seq::Tracks::GeneTrack::Build;
# use Seq::Tracks::ScoreTrack::Build;
# use Seq::Tracks::SparseTrack::Build;
# use Seq::Tracks::SnpTrack::Build;
# use Seq::Tracks::RegionTrack::Build;

use DDP;
# use Seq::Tracks::ReferenceTrack::Build;
# use Seq::Tracks::GeneTrack;
=property @public @required {Str} name

  The track name. This is defined directly in the input config file.

  @example:
  =for :list
  * gene
  * snp

=cut

state $typeKey = 't';
has typeKey => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$typeKey});


state $dataKey = 'd';
has dataKey => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$dataKey});

# I've coupled this to gene
# state $ngeneType = 'ngene';
# has ngeneType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$ngeneType});

state $refType = 'ref';
has refType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$refType});

state $geneType = 'gene';
has geneType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$geneType});

state $scoreType = 'score';
has scoreType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$scoreType});

state $sparseType = 'sparse';
has sparseType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$sparseType});

state $regionType = 'region';
has regionType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$regionType});

enum TrackType => [$refType, $geneType, 
  $scoreType, $sparseType, $regionType];

#Convert types; Could move the conversion code elsewehre,
#but I wanted types definition close to implementation

enum DataType => ['float', 'int'];

#idiomatic way to re-use a stack, gain some efficiency
#expects ->convert('string or number', 'type')
sub convert {
  goto &{$_[2]}; #2nd argument, with $self == $_[0]
}

#For numeric types we need to check if we were given a weird string
#not certain if we should return, warn, or what
#in bioinformatics it seems very common to use "NA" or a "." or "-" to
#depict missing data

#@param {Str | Num} $_[1] : the data
sub float {
  if (!looks_like_number($_[1] ) ) {
    return $_[1];
  }
  return sprintf( '%.6f', $_[1] );
}

#@param {Str | Num} $_[1] : the data
sub int {
  if (!looks_like_number($_[1] ) ) {
    return $_[1];
  }
  return sprintf( '%d', $_[1] );
}

no Moose::Role;
1;