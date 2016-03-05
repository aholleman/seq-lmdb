use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::SnpTrack;

our $VERSION = '0.001';

# ABSTRACT: Builds a snp track using dbSnp data, derived from UCSC
# VERSION

=head1 DESCRIPTION

  @class Seq::Build::SnpTrack

  # TODO: Check description
  A single-function, no public property class, which inserts type: snp
  SparseTrack records into a database.

  The input files may be any tab-delimited files with the following basic
  structure: `chrom, start, stop, name`. All columns should have a header and
  any additional columns should be defined as a `feature` in the configuration
  file. By default, the Seq::Fetch and Seq::Fetch::* packages will download and
  write the data in the proper format from a sql server (e.g., UCSC's public
  mysql server).

  @example  my $snp_db = Seq::Build::SnpTrack->new($record);

Used in:
=for :list
* Seq::Build

Extended by: None

=cut

use Moose 2;

use File::Path qw/ make_path /;
use File::Spec;
use namespace::autoclean;

use Seq::Site::Snp;

extends 'Seq::Tracks::SparseTrack';
with 'Seq::Role::IO';

__PACKAGE__->meta->make_immutable;

1;
