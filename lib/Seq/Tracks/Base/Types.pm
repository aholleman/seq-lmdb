use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base::Types;

our $VERSION = '0.001';

# ABSTRACT: Defines general track information: valid track "types", 
# track casting (data) types
# VERSION

use Moose::Role;
use Moose::Util::TypeConstraints; 
use namespace::autoclean;
use Scalar::Util qw/looks_like_number/;

coerce 'HashRef', from 'ArrayRef', via { $_ => $_ };

#What the types must be called in the config file
state $refType = 'ref';
has refType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$refType});

state $scoreType = 'score';
has scoreType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$scoreType});

state $sparseType = 'sparse';
has sparseType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$sparseType});

state $regionType = 'region';
has regionType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$regionType});

state $geneType = 'gene';
has geneType => (is => 'ro', init_arg => undef, lazy => 1, default => sub{$geneType});


enum TrackType => [$refType, $scoreType, $sparseType, $regionType, $geneType];

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

#moved away from this; the base build class shouldn't need to know 
#what types are allowed, that info is kep in the various track modules
#this is a simple-minded way to enforce a bed-only format
#this should not be used for things with single-field headers
#like wig or multi-fasta (or fasta)
# enum BedFieldType => ['chrom', 'chromStart', 'chromEnd'];

no Moose::Role;
no Moose::Util::TypeConstraints;
1;