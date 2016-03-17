use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::SparseTrack::Definition;

our $VERSION = '0.001';

# ABSTRACT: Defines general track information: valid track "types", 
# track casting (data) types
# VERSION

use Moose::Role;
use Moose::Util::TypeConstraints; 
use namespace::autoclean;
use Scalar::Util qw/looks_like_number/;

state $chrom = 'chrom';
state $cStart = 'chromStart';
state $cEnd   = 'chromEnd';
#TODO: allow people to map these names in YAML, via -blah: chrom -blah2: chromStart

has '+required_fields' => (
  default => sub{ [$chrom, $cStart, $cEnd] },
);

enum BedFieldType => [$chrom, $cStart, $cEnd];

no Moose::Role;
1;