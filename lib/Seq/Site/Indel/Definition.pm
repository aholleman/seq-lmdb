use strict;
use warnings;

package Seq::Site::Indel::Definition;

our $VERSION = '0.001';

# ABSTRACT: A class for emiting indel features
# VERSION

use Moose;
use Moose::Util::TypeConstraints;
use Scalar::Util qw(looks_like_number);
with 'Seq::Role::Message';
#with 'Seq::Site::Gene::Definition'; #for remaking the AA, later

#############BUILD#################
#Force insertions to be +[A-G]+ instead of numeric
#Because this has implications on how the minor_allele is calcualted
#For deletions, since we tend to gather all bases, can conver -N to a -[A-G]+
#In insertion case, at most we get abs_pos and flanking sites
sub BUILD {
  my $self = shift;
  if ( $self->indType eq '-' ) {
    if ( !looks_like_number( $self->minor_allele ) ) {
      return $self->log( 'error',
        'Site::Indel expects deletion alleles to be numeric' );
    }
  } else {
    if ( looks_like_number( $self->minor_allele ) ) {
      $self->log( 'error',
        'Site::Indel expects insertion alleles to consist of letters after +' );
    }
  }
}
######################Public Attributes##################
has minor_allele => (
  is       => 'rw',
  isa      => 'Str',
  writer   => '_rename_minor_allele',
  required => 1,
);

has annotation_type => (
  is      => 'rw',
  isa     => 'Str',
  lazy    => 1,
  writer  => 'set_annotation_type',
  default => '',                   #or NA?
);

#############Protected Api; typically not consumed################
# takes a string of bases
sub renameMinorAllele {
  my ( $self, $newName ) = @_;
  $self->_rename_minor_allele( $self->indType . $newName );
}

# will hard crash if bad input, as soon as it's called
enum IndTypes => [qw(- +)];
has indType   => (
  is      => 'ro',
  isa     => 'IndTypes',
  lazy    => 1,
  builder => '_build_indel_type',
);

sub _build_indel_type {
  my $self = shift;
  #cast as str to substr in case of -N
  return substr( "" . $self->minor_allele, 0, 1 );
}

has indLength => (
  is      => 'ro',
  isa     => 'Num',
  lazy    => 1,
  builder => '_build_indel_length',
);

# we only allow numeric for deletions;
# we could also do the check around
sub _build_indel_length {
  my $self = shift;
  if ( $self->indType eq '-' ) {
    return abs( int( $self->minor_allele ) );
  }
  return length( substr( $self->minor_allele, 1 ) );
}

has typeName => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_buildTypeName',
);

sub _buildTypeName {
  my $self = shift;
  return $self->indType eq '-' ? 'Del' : 'Ins';
}

#this is very basic; does not check if coding region
#so look for frame type only when coding (only then does it make sense)
has frameType => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  builder => '_buildFrameType',
);

sub _buildFrameType {
  my ( $self, $siteType ) = @_;
  my $frame = $self->indLength % 3 ? 'FrameShift' : 'InFrame';
}

# for now not calculating refAAresidues
# has refAAresidue => (
#   is => 'rw',
#   isa => 'Str',
#   lazy => 1,
#   default => '', #or NA?
# );

# has new_codon_seq => (
#   is      => 'ro',
#   isa     => 'Maybe[Str]',
#   lazy    => 1,
#   builder => '_set_new_codon_seq',
# );

# has new_aa_residue => (
#   is      => 'ro',
#   isa     => 'Maybe[Str]',
#   lazy    => 1,
#   builder => '_set_new_aa_residue',
# );

# #this won't work for now
# sub _set_new_codon_seq {
#   my $self = shift;

#   if ( $self->ref_codon_seq ) {
#     return $self->indType . $self->indLength;
#   }
#   else {
#     return;
#   }
# }

# sub _set_new_aa_residue {
#   my $self = shift;

#   if ( $self->new_codon_seq ) {
#     return $self->indType . $self->indLength;
#   }
#   else {
#     return;
#   }
# }

# sub makeCodonSeq {
#   my ($self, $beginEnd) = @_;
#   if($self->indType eq '-') {

#   }
# }
# #we expect a single argument, a scalar or scalar ref
# around BUILDARGS => sub {
#   my $orig = shift;
#   my $class = shift;

#   if (ref $_[0] eq 'HASH') {
#     $class->$orig($_[0]);
#   }

#   my $allele = $_[0];
#   #alternatively can let hard crash
#   if(!$allele) {
#     confess "Error: $class expects simple scalar or scalar ref, falsy passed";
#   }
#   if(ref $allele) {
#     if(ref $allele ne 'SCALAR') { confess "$class accepts only scalar refs"};
#     $allele = $$allele;
#   }

#   $class->$orig(minor_allele => $allele);
# };

__PACKAGE__->meta->make_immutable;
1;
