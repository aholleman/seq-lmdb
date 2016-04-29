#we expect the following features. lets give them some human readable names
use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Site::SiteKeys;
use Moose::Role 2;
use namespace::autoclean;

#we expect the following features. lets give them some human readable names
state $siteTypeKey = 'siteType';
state $strandKey = 'strand';
state $codonNumberKey = 'codonNumber';
state $codonPositionKey = 'codonPosition';
state $codonSequenceKey = 'codon';
state $peptideKey = 'aminoAcid';
has siteTypeKey => (is => 'ro', init_arg => undef, lazy => 1, default => $siteTypeKey);
has strandKey => (is => 'ro', init_arg => undef, lazy => 1, default => $strandKey);
has codonNumberKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonNumberKey);
has codonPositionKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonPositionKey);
has codonSequenceKey => (is => 'ro', init_arg => undef, lazy => 1, default => $codonSequenceKey);
has peptideKey => (is => 'ro', init_arg => undef, lazy => 1, default => $peptideKey);

#the reason I'm not calling self here, is like in most other packages I'm writing
#trying to stay away from use of moose methods for items declared within the package
#it adds overhead, and absolutely no clearity imo
#Moose should be used for the public facing API
sub allSiteKeys {
  return ($siteTypeKey, $strandKey, $codonNumberKey,
    $codonPositionKey, $codonSequenceKey, $peptideKey);
}

no Moose::Role;
1;