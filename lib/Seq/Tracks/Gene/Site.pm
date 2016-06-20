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
use Scalar::Util qw/looks_like_number/;
use DDP;

use Seq::Tracks::Gene::Site::SiteTypeMap;
use Seq::Tracks::Gene::Site::CodonMap;

#exports log method to $self
with 'Seq::Role::Message';

#since the two Site:: packages are tightly coupled to packedCodon and 
#unpackCodon, I am making them public
#internally using the variables directly, because when called tens of millions
#of times, $self->codonMap may cost noticeable performance
#TODO: test that theory
state $siteTypeMap = Seq::Tracks::Gene::Site::SiteTypeMap->new();
has siteTypeMap => (
  is => 'ro',
  init_arg => undef,
  lazy => 1,
  default => sub{ return $siteTypeMap },
);

state $codonMap = Seq::Tracks::Gene::Site::CodonMap->new();
has codonMap => (
  is => 'ro',
  init_arg => undef,
  lazy => 1,
  default => sub{ return $codonMap },
);

state $siteTypeKey = 'siteType';
has siteTypeKey => (is => 'ro', init_arg => undef, lazy => 1, default => $siteTypeKey);
state $strandKey = 'strand';
has strandKey => (is => 'ro', init_arg => undef, lazy => 1, default => $strandKey);
state $codonNumberKey = 'referenceCodonNumber';
has codonNumberKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonNumberKey);
state $codonPositionKey = 'referenceCodonPosition';
has codonPositionKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonPositionKey);
state $codonSequenceKey = 'referenceCodon';
has codonSequenceKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonSequenceKey);

#the reason I'm not calling self here, is like in most other packages I'm writing
#trying to stay away from use of moose methods for items declared within the package
#it adds overhead, and absolutely no clearity imo
#Moose should be used for the public facing API
sub allSiteKeys {
  return ($siteTypeKey, $strandKey, $codonNumberKey,
    $codonPositionKey, $codonSequenceKey);
}

#some default value that is less than 0, which is a valid idx
state $missingNumber = -9;

#pack strands as small integers, save a byte in messagepack
state $strandMap = { '-' => 0, '+' => 1, };
state $strandMapInverse = ['-', '+'];

# Cost to pack an array using messagePack (which happens by default)
# Should be the same as the overhead for messagePack storing a string
# Unless the Perl messagePack implementation isn't good
# So store as array to save pack / unpack overhead
sub packCodon {
  my ($self, $siteType, $strand, $codonNumber, $codonPosition, $codonSeq) = @_;

  my @outArray;

  #used to require strand too, but that may go away
  if( !$siteType ) {
    $self->log('fatal', 'packCodon requires site type');
  }

  my $siteTypeNum = $siteTypeMap->getSiteTypeNum( $siteType );

  if(!defined $siteTypeNum) {
    $self->log('fatal', "site type $siteType not recognized");
  }

  #We only require siteTypeNum
  push @outArray, $siteTypeNum;

  if( $strand ) {
    if( ! defined $strandMap->{$strand} ) {
      $self->log('fatal', "Strand strand should be a + or -, got $strand");
    }

    push @outArray, $strandMap->{$strand};
  }

  if(defined $codonNumber || defined $codonPosition || defined $codonSeq) {
    if(!defined $codonNumber && !defined $codonPosition && !defined $codonSeq) {
      $self->log('fatal', "Codons must be given codonNumber, codonPosition, and codonSeq"); 
    }

    if( !(looks_like_number( $codonPosition ) && looks_like_number( $codonNumber) ) ) {
      $self->log('fatal', 'codonPosition & codonNumber must be numeric');
    }

    my $codonSeqNumber;

    if(defined $codonSeq) {
      $codonSeqNumber = $codonMap->codon2Num($codonSeq);

      #warning for now, this mimics the original codebase
      #TODO: do we want to store this as an error in the TX?
      if(!$codonSeqNumber) {
        $self->log('warn', "couldn\'t convert codon sequence $codonSeq to a number");

        $codonSeqNumber = $missingNumber;
      }
    }

    push @outArray, $codonNumber;
    push @outArray, $codonPosition;
    push @outArray, $codonSeqNumber;
  }

  return \@outArray;
}
#@param <Seq::Tracks::Gene::Site> $self
#@param <ArrayRef> $codon
sub unpackCodon {
  #$_[1] is an array ref, containing the codon of interest
  return {
    #site types are always required
    $siteTypeKey => $siteTypeMap->getSiteTypeFromNum($_[1]->[0]),
    #so are strands, but later I can imagine relaxing this
    $strandKey => defined $_[1]->[1] ? $strandMapInverse->[ $_[1]->[1] ] : undef,
    #optional; values that may not exist (say a non-coding site)
    $codonNumberKey => $_[1]->[2],
    $codonPositionKey => $_[1]->[3],
    $codonSequenceKey => defined $_[1]->[4] && $_[1]->[4] > $missingNumber 
      ? $codonMap->num2Codon( $_[1]->[4] ) : undef,
  };
}

#Future API

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