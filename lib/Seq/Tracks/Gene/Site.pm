use 5.10.0;
use strict;
use warnings;

#The goal of this is to both set and retrieve the information for a single
#position requested by the user
#So what is stored here is for the main database, and not 
#Breaking this thing down to fit in the new contxt
#based on Seq::Gene in (kyoto-based) seq branch
#except _get_gene_data moved to Seq::Tracks::GeneTrack::Build
package Seq::Tracks::Gene::Site;
use Moose 2;
use List::Util qw/first/;
use Scalar::Util qw/looks_like_number/;
use DDP;

with 'Seq::Tracks::Gene::Site::Definition', 'Seq::Role::Message';

#To save performance, we support arrays, making this a bit like a full TX
#writer, but on a site by site basis
state $missingNumber = -9; #some default value that is less than 0, which is a valid idx

#expects a single href, which contains everything associated with the 
#transcript at a particular site
# sub getTXsite {
#   # my $self = shift; $_[0] == $self
#   my ($self, $href) = @_;

#   my $outHref;
#   for my $key (keys %$href) {
#     if ($featureMap->{$key} eq 'codonDetails') {
#       $outHref->{ $featureMap->{$key} } = 
#         $self->unpackCodon( $href->{$key} );
#       next;
#     }

#     $outHref->{ $featureMap->{$key} } = $href->{$key};
#   }

#   return $outHref;
# }

sub packCodon {
  my ($self, $siteType, $strand, $codonNumber, $codonPosition, $codonSeq) = @_;

  #used to require strand too, but that may go away
  if( !$siteType ) {
    $self->log('fatal', 'packCodon requires site type');
  } elsif(! first { $_ eq $strand } $self->allStrandTypes ) {
    $self->log('fatal', 'strand must be of StrandType');
  }

  my $siteTypeNum = $self->getSiteTypeNum( $siteType );

  if(!defined $siteTypeNum) {
    $self->log('fatal', "site type $siteType not recognized. Is it a GeneSite?");
  }

  if(defined $codonNumber && !defined $codonPosition) {
    $self->log('fatal', 'if codon number provided also need Position');
  }

  if( defined $codonPosition && defined $codonNumber && 
  !(looks_like_number( $codonPosition ) && looks_like_number( $codonNumber) ) ) {
    $self->log('fatal', 'codon position & Number must be numeric');
  }

  if(defined $codonSeq && (!defined $codonPosition || !defined $codonNumber) ) {
    $self->log('fatal', 'codon sequence requires codonPosition or codonNumber');
  }

  #c = signed char; A = ASCII string space padded, l = signed long
  #usign signed values to allow for missing data
  #https://ideone.com/TFGjte
  return pack('cAlcAAA', $siteTypeNum, $strand,
    defined $codonNumber ? $codonNumber : $missingNumber,
    defined $codonPosition ? $codonPosition : $missingNumber,
    defined $codonSeq ? split ('', $codonSeq) : ('','','') );
}

#Purpose of the following functions is to internally store the unpacked
#codon code, and then allow the consumer to get the individual pieces of 
#the convoluted codon detail string
#I like the idea of hiding the implementation of the api
#so I'm not returning the raw unpacked array
#The goal of this class is to fill $unpackedCodon, but consumer 
#can also use $unpackedCodon directly
my $unpackedCodon;
sub unpackCodon {
  #my ($self, $codonStr) = @_;
  #$codonStr == $_[1] 
  #may be called a lot, so not using arg assignment
  #https://ideone.com/TFGjte
  $unpackedCodon = unpack('cAlcAAA', $_[1]);
  return $unpackedCodon;
}

#save some computation by not shifting $self (and storing deconv as simple array ref)
sub getCodonSiteType {
  #my $self = shift;
  #$self == $_[0] , skipping assignment for performance
  return $_[0]->siteTypeMap->{ $unpackedCodon->[0] };
}

sub getCodonStrand {
  return $unpackedCodon->[1];
}

sub getCodonNum {
  return $unpackedCodon->[2];
}

sub getCodonPos {
  return $unpackedCodon->[3];
}

#https://ideone.com/cNQfwv
sub getCodonSeq {
  return join('', @$unpackedCodon[4..6] );
}

# not in use yet
# sub hasCodon {
#   my ($self, $href) = @_;

#   return !!$href->{ $invFeatureMap->{refCodonSequence} };
# }

__PACKAGE__->meta->make_immutable;
1;