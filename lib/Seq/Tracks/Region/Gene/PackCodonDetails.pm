use 5.10.0;
use strict;
use warnings;

#Breaking this thing down to fit in the new contxt
#based on Seq::Gene in (kyoto-based) seq branch
#except _get_gene_data moved to Seq::Tracks::GeneTrack::Build
package Seq::Tracks::Region::Gene::TX::PackCodonDetails;

use Moose::Role 2;
with 'Seq::Site::Definition'; #exports types used below
with 'Seq::Role::Message';

use List::Util qw/first/;
use Scalar::Util qw/looks_like_number/;
#@public methods
#giving codon number a large number, in case we have some insanely large protein
#The largest currently known is Titin, has up to 33k AA / codons, so 
#it is formally possible that a short won't cover it

#originally I had this using Moosey methods; but I want to avoid 
#instantiation overhead, so will check for keynames instead
# sub convoluteCodonDetails {
#   my $self = shift;

#   return pack('ACLC', $self->strand, $self->codonPosition, 
#     $self->codonNumber, $self->getSiteTypeNum($self->siteType)  )
# }

#@arguments
#no longer needed, since I manually check the presence of these arguments
# requires 'codonNumber';
# requires 'codonPosition';
sub convoluteCodonDetails {
  my ($self, $siteType, $strand, $codonPosition, $codonNumber) = @_;

  if( !($siteType && $strand && $codonPosition && $codonNumber) ) {
    $self->tee_logger('error', 'convoluteCodonDetails requires strand,
      codonPosition, codonNumber, siteType');
    die;
  }

  if(! first { $_ eq $strand } $self->allStrandTypes ) {
    $self->tee_logger('error', 'strand must be of StrandType');
    die;
  }

  my $siteTypeNum = $self->getSiteTypeNum( $siteType );

  if(!$siteTypeNum) {
    $self->tee_logger('error', 'siteType must be of GeneSites type');
    die;
  }

  if( !(looks_like_number($codonPosition) && looks_like_number( $codonNumber) ) ) {
    $self->tee_logger('error', 'codonPosition and codonNumber must be numeric');
    die;
  }
  #c = signed char; A = ASCII string space padded, l = signed long
  #usign signed values to allow for missing data
  #(say -9, or whatever the consumer wants)
  return pack('cAlc', $self->getSiteTypeNum($siteType), $strand,
    $codonNumber, $codonPosition);
}

#Purpose of the following functions is to internally store the unpacked
#codon code, and then allow the consumer to get the individual pieces of 
#the convoluted codon detail string
#I like the idea of hiding the implementation of the api
#so I'm not returning the raw unpacked array
my $deconvolutedCodon;
sub deconvoluteCodonDetails {
  #my ($self, $codonStr) = @_;
  #$codonStr == $_[1] 
  #may be called a lot, so not using arg assignment
  $deconvolutedCodon = unpack('cAlc', $_[1]);
}

#save some computation by not shifting $self (and storing deconv as simple array ref)
sub getSiteType {
  #my $self = shift;
  #$self == $_[0] , skipping assignment for performance
  return $_[0]->siteTypeMap->{ $deconvolutedCodon->[0] };
}

sub getStrand {
  return $deconvolutedCodon->[1];
}

sub getCodonNum {
  return $deconvolutedCodon->[2];
}

sub getCodonPos {
  return $deconvolutedCodon->[3];
}

#this is not just required, because we expecte StrandType only (needed for packing)
# has strand => (
#   is => 'ro',
#   required => 1,
#   isa => 'StrandType',
# );
# #this is not just required, because we expected GeneSiteType only
# has siteType => (
#   is => 'ro',
#   isa => 'GeneSiteType',
#   required => 1,
# );

#TODO: should constrain values to GeneSiteType
has _siteTypeMap => (
  is => 'ro',
  isa => 'ArrayRef[GeneSite]',
  traits => ['Array'],
  lazy => 1,
  builder => '_buildSiteTypeMap',
);

sub _buildSiteTypeMap {
  my $self = shift;

  return [
    $self->ncRNAsiteType,
    $self->codingSiteType,
    $self->threePrimeSiteType,
    $self->fivePrimeSiteType,
    $self->spliceAcSite,
    $self->spliceDoSite,
  ];
}

#TODO: can we specify GeneSiteType in hashref
has siteTypeMapInverse => (
  is => 'ro',
  lazy => 1,
  isa => 'HashRef',
  traits => ['Hash'],
  handles => {
    getSiteTypeNum => 'get',
  },
  builder => '_buildSiteTypeMapInverse',
);

state $mapInverse;
sub _buildSiteTypeMapInverse {
  if($mapInverse) {
    return $mapInverse;
  }

  my $self = shift;

  my $href;
  for (my $i = 0; $i < @{ $self->_siteTypeMap }; $i++ ) {
    $href->{ $self->_siteTypeMap->[$i] } = $i;
  }

  return { 
    $self->ncRNAsiteType => 0,
    $self->codingSiteType => 1,
    $self->threePrimeSiteType => 2,
    $self->fivePrimeSiteType => 3,
    $self->spliceAcSite => 4,
    $self->spliceDoSite => 5,
  }
}