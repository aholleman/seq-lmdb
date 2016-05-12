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

with 'Seq::Tracks::Gene::Site::SiteTypeMap',
'Seq::Tracks::Gene::Site::CodonMap',
#exports strandTypes
'Seq::Site::Definition',
'Seq::Role::Message';


state $siteTypeKey = 'siteType';
state $strandKey = 'strand';
state $codonNumberKey = 'codonNumber';
state $codonPositionKey = 'codonPosition';
state $codonSequenceKey = 'codon';
state $peptideKey = 'aminoAcid';

has siteTypeKey => (is => 'ro', init_arg => undef, lazy => 1, default => $siteTypeKey);
# Not exposing at the moment because not used anywhere
# has strandKey => (is => 'ro', init_arg => undef, lazy => 1, default => $strandKey);
# has codonNumberKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonNumberKey);
# has codonPositionKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonPositionKey);
# has codonSequenceKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonSequenceKey);
# has peptideKey => (is => 'ro', init_arg => undef, lazy => 1, default => $peptideKey);

#the reason I'm not calling self here, is like in most other packages I'm writing
#trying to stay away from use of moose methods for items declared within the package
#it adds overhead, and absolutely no clearity imo
#Moose should be used for the public facing API
sub allSiteKeys {
  return ($siteTypeKey, $strandKey, $codonNumberKey,
    $codonPositionKey, $codonSequenceKey, $peptideKey);
}
state $numSiteKeys = 6;

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

# Check all arguments carefully, so that at Get time, we won't have issues
# (unless database is corrupted, then we want things to fail early)
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

  my $codonSeqNumber;

  if(defined $codonSeq) {
    $codonSeqNumber = $self->codon2Num($codonSeq);

    # say "codon2SeqNumber is ";
    # p $codonSeqNumber;
    
    if(!$codonSeqNumber) {
      die 'couldn\'t convert codon sequence $codonSeq to a number';
      $self->log('fatal', "couldn\'t convert codon sequence $codonSeq to a number");
    }
  }

  #  say "codonSeqNumber is $codonSeqNumber";
  # say "codon number is $codonNumber";
  # say "codon position is $codonPosition";

  #return [$siteTypeNum, $strand, $codonNumber, $codonPosition, $codonSeqNumber];
  #no longer doing this, benefit is minimal; messagepack will already
  #do something similar, so it's almost processing the same info twice
  #c = signed char; A = ASCII string space padded, l = signed long
  #usign signed values to allow for missing data
  #https://ideone.com/TFGjte
  return pack('cAlcc', $siteTypeNum, $strand,
    defined $codonNumber ? $codonNumber : $missingNumber,
    defined $codonPosition ? $codonPosition : $missingNumber,
    defined $codonSeqNumber ? $codonSeqNumber : $missingNumber);
}

#Purpose of the following functions is to internally store the unpacked
#codon code, and then allow the consumer to get the individual pieces of 
#the convoluted codon detail string
#I like the idea of hiding the implementation of the api
#so I'm not returning the raw unpacked array
#The goal of this class is to fill $unpackedCodon, but consumer 
#can also use $unpackedCodon directly

#if all fields are filled then we will return
# {
#   $siteTypeKey => val,
#   $strandKey => val,
#   $codonNumberKey => val,
#   $codonPositionKey => val,
#   $codonSequenceKey => val,
#   $peptideKey => val,
# }
#I've decided to always return the same keys, to make consumption more consistent
#and allow consuming classes decide what to keep or discard
#anything thta isn't present is given a key => undef pair
#storing outside the sub to allow other (future) methods to grab data from it
#and since it won't be public, won't use moose to expose it
sub unpackCodon {
  #my ($self, $codoAref) = @_;
  #$codonStr == $_[1] 
  #may be called a lot, so not using arg assignment
  #Old version relied on pack/unpack, here are some informal tests:
   #https://ideone.com/TFGjte
    #https://ideone.com/dVy6WL
    #my @unpackedCodon = $_[1] ? unpack('cAlcAAA', $_[1]) : (); 
    #etc
  # if(@{ $_[1] } > $numSiteKeys) {
  #   goto &_unpackCodonBulk;
  # }
  my @codon = unpack('cAlcc', $_[1]);

  return {
    $siteTypeKey => defined $codon[0] ? $_[0]->getSiteTypeFromNum($codon[0]) : undef,
    $strandKey => $codon[1],
    $codonNumberKey => $codon[2] > $missingNumber ? $codon[2] : undef,
    $codonPositionKey => $codon[3] > $missingNumber ? $codon[3] : undef,
    $peptideKey => $codon[4] > $missingNumber ? $_[0]->codon2aa( $_[0]->num2Codon( $codon[4] ) ) : undef
  };
}

# sub _unpackCodonBulk {
#   #my ($self, $codoAref) = @_;
#   #$codonStr == $_[1] 
#   #may be called a lot, so not using arg assignment
#   #Old version relied on pack/unpack, here are some informal tests:
#    #https://ideone.com/TFGjte
#     #https://ideone.com/dVy6WL
#     #my @unpackedCodon = $_[1] ? unpack('cAlcAAA', $_[1]) : (); 
#     #etc

#   for(my $i)

#   return {
#     $siteTypeKey => defined $_[1]->[0] ? $_[0]->getSiteTypeFromNum($_[1]->[0]) : undef,
#     $strandKey => $_[1]->[1],
#     $codonNumberKey => $_[1]->[2],
#     $codonPositionKey => $_[1]->[3],
#     $peptideKey => defined $_[1]->[4] ? $_[0]->codon2aa( $_[0]->num2Codon($_[1]->[4]) ) : undef
#   }
# }

#save some computation by not shifting $self (and storing deconv as simple array ref)
#in all the below $_[0] is $self
#not assigning to $self because may be called millions - a billion times
sub getSiteTypeFromCodon {
  #my ($self, $unpackedCodon) = @_;
  #     $_[0],  $_[1]
  return $_[1]->{$siteTypeKey};
}

# sub getCodonStrand {
#   return $unpackedCodonHref->{$_[0]->strandKey};
# }

# sub getCodonNumber {
#   return $unpackedCodonHref->{$_[0]->codonNumberKey};
# }

# sub getCodonPosition {
#   return $unpackedCodonHref->{$_[0]->codonPositionKey};
# }

# #https://ideone.com/cNQfwv
# sub getCodonSequence {
#   return $unpackedCodonHref->{$_[0]->codonSequenceKey};
# }

# sub getCodonAAresidue {
#   return $unpackedCodonHref->{$_[0]->peptideKey};
# }

# not in use yet
# sub hasCodon {
#   my ($self, $href) = @_;

#   return !!$href->{ $invFeatureMap->{refCodonSequence} };
# }

__PACKAGE__->meta->make_immutable;
1;