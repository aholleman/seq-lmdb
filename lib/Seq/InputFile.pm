package Seq::InputFile;

our $VERSION = '0.001';

# ABSTRACT: Checks validity of input file, and knows about input file header
# VERSION

use 5.10.0;
use strict;
use warnings;

use Moose 2;

use MooseX::Types::Path::Tiny qw/AbsPath/;
use Moose::Util::TypeConstraints;
use File::Which qw(which);
use File::Basename;
use List::MoreUtils qw(firstidx);
use namespace::autoclean;
use DDP;

with 'Seq::Role::Message';

# the minimum required snp headers that we actually have
# we use singleton pattern because we expect to annotate only one file
# per run
state $requiredInputHeaderFields = {
  snp_1 => [qw/ Fragment Position Reference Minor_allele Type /],
  snp_2 => [qw/ Fragment Position Reference Alleles Allele_Counts Type/]
};

state $allowedFileTypes = [ keys %$requiredInputHeaderFields ];
enum fileTypes => $allowedFileTypes;

state $snpFieldIndices = [];
has snpFieldIndices => (
  is => 'ro',
  isa => 'ArrayRef',
  traits => ['Array'],
  init_arg => undef,
  lazy => 1,
  default => sub{ $snpFieldIndices },
  writer => '_setSnpFieldIndices',
);

#again, singleton because 1 file per annotator run
#not meant to be set by user
state $fileType = '';
has file_type => (
  is       => 'ro',
  isa      => 'fileTypes',
  init_arg => undef,
  lazy => 1,
  default  => $fileType,
  writer => '_setFileType',
);

# @ public only the common fields exposed
has fragmentFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Fragment');

has positionFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Position');

has referenceFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Reference');

has typeFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Type');

has alleleFieldName => ( is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;

  if($self->file_type eq 'snp_2') {
    return 'Allele';
  } elsif ($self->file_type eq 'snp_1') {
    return 'Minor_allele';
  }

  $self->log('fatal', "Don't recognize file type " . $self->file_type);
});

has fragmentFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 0);

has positionFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 1);

has referenceFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 2);

has alleleFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 3);

has typeFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;
  if($self->file_type eq 'snp_2') {
    return 5
  }
  return 4;
});

sub getSampleNamesIdx {
  my ($self, $fAref) = @_;
  my $strt = scalar @{ $requiredInputHeaderFields->{$self->file_type} };

  # every other field column name is blank, holds genotype probability 
  # for preceeding column's sample;
  # don't just check for ne '', to avoid simple header issues
  my %data;

  for(my $i = $strt; $i <= $#$fAref; $i += 2) {
    $data{$fAref->[$i] } = $i;
  }
  return %data;
}

# file_type defines the kind of file that is being annotated
#   - snp_1 => snpfile format: [ "Fragment", "Position", "Reference", "Minor_Allele"]
#   - snp_2 => snpfile format: ["Fragment", "Position", "Reference", "Alleles", "Allele_Counts", "Type"]
#   - vcf => placeholder



##########Private Variables##########

sub checkInputFileHeader {
  my ( $self, $field_aref, $die_on_unknown ) = @_;

  if(@$snpFieldIndices && $fileType) {
    $self->_setFileType($fileType);
    $self->_setSnpFieldIndices($snpFieldIndices);
    return;
  }

  $die_on_unknown = defined $die_on_unknown ? $die_on_unknown : 1;
  my $err;

  for my $type (@$allowedFileTypes) {
    $err = $self->_checkInvalid($field_aref, $type);
    if(!$err) {
      $fileType = $type;
      $snpFieldIndices = $requiredInputHeaderFields->{$type};
      last;
    }
  }

  if($err) {
    $err = 'Provided input file doesn\'t match allowable types';
    $self->log( 'fatal', $err); 
    return;
  }

  return 1;
}

# checks whether the first N fields, where N is the number of fields defined in
# $self->allReqFields, in the input file match the reqFields values
# order however in those first N fields doesn't matter
sub _checkInvalid {
  my ($self, $aRef, $type) = @_;

  my $reqFields = $requiredInputHeaderFields->{$type};

  my @inSlice = @$aRef[0 .. $#$reqFields];

  my $idx;
  for my $reqField (@$reqFields) {
    $idx = firstidx { $_ eq $reqField } @inSlice;
    if($idx == -1) {
      return "Input file header misformed. Coudln't find $reqField in first " 
        . @inSlice . ' fields.';
    }
  }
  return;
}
#presumes that _file_type exists and has corresponding key in _headerFields
#this can be called millions of times
#However, it seems unnecessary to put out here, added it back to the caller (Seq.pm)
# sub getSnpFields {
#   #my ( $self, $fieldsAref ) = @_;
#   #$_[0] == $self, $_[1 ] == $fieldAref

#   return map {$_[1]->[$_] } $_[0]->allSnpFieldIdx;
# }

__PACKAGE__->meta->make_immutable;
1;
