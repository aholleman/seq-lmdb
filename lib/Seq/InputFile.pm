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

with 'Seq::Role::Message';

# the minimum required snp headers that we actually have
# we use singleton pattern because we expect to annotate only one file
# per run
# order matters, we expect the first N fields to be what is defined here
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

#The file type that was found;
#@private
state $fileType = '';

# @ public only the common fields exposed
has chrFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Fragment');

has positionFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Position');

has referenceFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Reference');

has typeFieldName => ( is => 'ro', init_arg => undef, lazy => 1,
  default => 'Type');

has alleleFieldName => ( is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;

  if($fileType eq 'snp_2') {
    return 'Allele';
  } elsif ($fileType eq 'snp_1') {
    return 'Minor_allele';
  }

  $self->log('fatal', "Don't recognize file type: $fileType");
});

has chrFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 0);

has positionFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 1);

has referenceFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 2);

has alleleFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => 3);

has typeFieldIdx => ( is => 'ro', init_arg => undef, lazy => 1, default => sub {
  my $self = shift;
  if($fileType eq 'snp_2') {
    return 5
  }
  return 4;
});

sub getSampleNamesIdx {
  my ($self, $fAref) = @_;
  my $strt = scalar @{ $requiredInputHeaderFields->{$fileType} };

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

  if(@$snpFieldIndices && $fileType) {
    $self->_setSnpFieldIndices($snpFieldIndices);

    return 1;
  }

  for my $type (@$allowedFileTypes) {
    my $requiredFields = $requiredInputHeaderFields->{$type};

    my $notFound;
    my @fieldIndices = ( 0 .. $#$requiredFields );

    INNER: for my $index (@fieldIndices) {
      if($inputFieldsAref->[$index] ne $requiredFields->[$index]) {
        $notFound = 1;
        last INNER;
      }
    }

    if(!$notFound) {
      $fileType = $type;
      $snpFieldIndices = \@fieldIndices;
      $self->_setSnpFieldIndices($snpFieldIndices);
      
      return 1;
    }
  }

  if($dontDieOnUnkown) {
    return;
  }

  $self->log( 'fatal', "Provided input file isn't of an allowed type");
}

__PACKAGE__->meta->make_immutable;
1;
