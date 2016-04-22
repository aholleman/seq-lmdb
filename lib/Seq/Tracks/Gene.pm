use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene;

our $VERSION = '0.001';

# ABSTRACT: Class for creating particular sites for a given gene / transcript
# This track is a lot like a region track
# The differences:
# We will bulk load all of its region database into a hash
# {
#   geneID or 0-N position : {
#       features
#}  
#}
# (We could also use a number as a key, using geneID would save space
# as we avoid needing 1 key : value pair
# and gain some meaningful information in the key
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Gene>
  #TODO: Check description

  @example

Used in:
=for :list
* Seq::Build::GeneTrack
    Which is used in Seq::Build
* Seq::Build::TxTrack
    Which is used in Seq::Build

Extended by: None

=cut

use Moose 2;

use Carp qw/ confess /;
use namespace::autoclean;
use Data::Dump qw/ dump /;

use Seq::Site::Gene;

with 'Seq::Gene::Definition';

#TODO: make this, this is the getter

#The only job of this package is to ovload the base get method, and return
#all the info we have.
#This is different from typical getters, in that we have 2 sources of info
#The site info and the region info
#A user can only specify region features they want

__PACKAGE__->meta->make_immutable;

1;
