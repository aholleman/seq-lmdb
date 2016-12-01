package Seq::InputFile;

our $VERSION = '0.001';

# ABSTRACT: Checks validity of input file, and knows about input file header
# VERSION

use 5.10.0;
use strict;
use warnings;

use Mouse 2;

use Types::Path::Tiny qw/AbsPath/;
use Mouse::Util::TypeConstraints;
use File::Which qw(which);
use File::Basename;
use List::MoreUtils qw(firstidx);
use namespace::autoclean;
use DDP;
use List::Util qw( max );

with 'Seq::Role::Message';

# the minimum required snp headers that we actually have
# we use singleton pattern because we expect to annotate only one file
# per run
# order matters, we expect the first N fields to be what is defined here

# TODO : Simplify this; just look for any order of headers in the first 5-6 columns
# state $requiredInputHeaderFields = {
#   snp_1 => [qw/ Fragment Position Reference Minor_allele Type /],
#   snp_2 => [qw/ Fragment Position Reference Alleles Allele_Counts Type/],
#   snp_3 => [qw/ Fragment Position Reference Type Alleles Allele_Counts/]
# };

state $requiredInputHeaderFields = {
  chrField => qr/Fragment/i,
  positionField => qr/Position/i,
  referenceField => qr/Reference/i,
  alleleField => qr/Alleles|Minor_allele/i,
  typeField => qr/Type/i,
};

state $optionalInputHeaderFields = {
  alleleCountField => qr/Allele_Counts/i,
};

# @ public only the common fields exposed
has chrFieldName => ( is => 'ro', init_arg => undef);

has positionFieldName => ( is => 'ro', init_arg => undef);

has referenceFieldName => ( is => 'ro', init_arg => undef);

has typeFieldName => ( is => 'ro', init_arg => undef);

has alleleFieldName => ( is => 'ro', init_arg => undef);

has alleleCountFieldName => ( is => 'ro', init_arg => undef);

has chrFieldIdx => ( is => 'ro', init_arg => undef);

has positionFieldIdx => ( is => 'ro', init_arg => undef);

has referenceFieldIdx => ( is => 'ro', init_arg => undef);

has alleleFieldIdx => ( is => 'ro', init_arg => undef);

has typeFieldIdx => ( is => 'ro', init_arg => undef);

has alleleCountFieldIdx => ( is => 'ro', init_arg => undef);

# The last field containing snp data; 5th or 6th
# Set in checkInputFileHeader
has lastSnpFileFieldIdx => ( is => 'ro', init_arg => undef, writer => '_setLastSnpFileFieldIdx');

# The first sample genotype field
# Set in checkInputFileHeader
# has firstSampleIdx => (is => 'ro', init_arg => undef, writer => '_setFirstSampleIdx');

sub getSampleNamesIdx {
  my ($self, $fAref) = @_;
  my $strt = $self->lastSnpFileFieldIdx + 1;

  # every other field column name is blank, holds genotype probability 
  # for preceeding column's sample;
  # don't just check for ne '', to avoid simple header issues
  my %data;
  
  for(my $i = $strt; $i <= $#$fAref; $i += 2) {
    $data{$fAref->[$i] } = $i;
  }
  
  return %data;
}

#uses the input file headers to figure out what the file type is
sub checkInputFileHeader {
  my ( $self, $inputFieldsAref, $dontDieOnUnkown ) = @_;

  my @firstFields = @$inputFieldsAref[0 .. 5];

  my $notFound;
  my @indicesFound;
  REQ_LOOP: for my $fieldType (keys %$requiredInputHeaderFields) {
    for (my $i = 0; $i < @firstFields; $i++) {
      if($firstFields[$i] =~ $requiredInputHeaderFields->{$fieldType} ) {
        $self->{$fieldType . "Name"} = $firstFields[$i];
        $self->{$fieldType . "Idx"} = $i;

        push @indicesFound, $i;
        next REQ_LOOP;
      }
    }

    $notFound = 1;
    last;
  }

  OPTIONAL: for my $fieldType (keys %$optionalInputHeaderFields) {
    for (my $i = 0; $i < @firstFields; $i++) {
      if($firstFields[$i] =~ $optionalInputHeaderFields->{$fieldType} ) {
        $self->{$fieldType . "Name"} = $firstFields[$i];
        $self->{$fieldType . "Idx"} = $i;

        push @indicesFound, $i;
      }
    }
  }

  my $lastSnpFileFieldIdx = max(@indicesFound);

  $self->_setLastSnpFileFieldIdx($lastSnpFileFieldIdx);

  # $self->_setFirstSampleIdx($lastSnpFileFieldIdx + 1);

  if($notFound) {
    if($dontDieOnUnkown) {
      return;
    }

    return $self->log( 'fatal', "Provided input file isn't of an allowed type");
  }

  return 1;
}

__PACKAGE__->meta->make_immutable;
1;
