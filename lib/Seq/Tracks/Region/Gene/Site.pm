use 5.10.0;
use strict;
use warnings;

#The goal of this is to both set and retrieve the information for a single
#position requested by the user
#So what is stored here is for the main database, and not 
#Breaking this thing down to fit in the new contxt
#based on Seq::Gene in (kyoto-based) seq branch
#except _get_gene_data moved to Seq::Tracks::GeneTrack::Build
package Seq::Tracks::Region::Gene::Site;
use Moose::Role 2;
with 'Seq::Tracks::Region::Gene::PackCodonDetails';
with 'Seq::Tracks::Region::Gene::TX::Definition';
with 'Seq::Site::Definition';

#To save performance, we support arrays, making this a bit like a full TX
#writer, but on a site by site basis

#for now we will hardcode the feature map
#later we may move away from this, as we start storing these mappings in the db
#could also move to arrays, since order is inherent there
state $featureMap = {
  0 => 'refCodonSequence',
  1 => 'refCodonDetails',
};

state $invFeatureMap = {
  'refCodonSequence' => 0,
  'refCodonDetails' => 1,
};


sub prepareCodonDetails {
  # my $self = shift; $_[0] == $self
  my ($self, $siteType, $codonNumber, $codonPosition, $codonSequence) = @_;

  my $outHref;

  #could also $outHref->{refCodonSequence} = $codonSequence ? $codonSequence : 'NA';
  if($codonSequence) {
    $outHref->{refCodonSequence} = $codonSequence;
  }

  $outHref->{refCodonDetails} = 
    $self->convoluteCodonDetails($siteType, $self->strand,
      $codonNumber, $codonPosition);
  #types are checked in PackCodonDetails
  return $outHref;
}

#expects a single href, which contains everything associated with the 
#transcript at a particular site
sub getTXsite {
  # my $self = shift; $_[0] == $self
  my ($self, $href) = @_;

  my $outHref;
  for my $key (keys %$href) {
    if ($featureMap->{$key} eq 'codonDetails') {
      $outHref->{ $featureMap->{$key} } = 
        $self->deconvoluteCodonDetails( $href->{$key} );
      next;
    }

    $outHref->{ $featureMap->{$key} } = $href->{$key};
  }

  return $outHref;
}

# not in use yet
# sub hasCodon {
#   my ($self, $href) = @_;

#   return !!$href->{ $invFeatureMap->{refCodonSequence} };
# }

__PACKAGE__->meta->make_immutable;
1;