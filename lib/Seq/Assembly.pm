use 5.10.0;
use strict;
use warnings;

package Seq::Assembly;

our $VERSION = '0.002';

#TODO: turn this into a base class that sets up the logger ?
#I think this class should hold all of the common stuff, much lke the previous version

# ABSTRACT: A class for assembly information
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Assembly>
  # TODO: Check description

  @example

Used in: None

Extended by:
=for :list
* Seq::Annotate
* Seq::Build

Uses:
=for :list
* Seq::Config::GenomeSizedTrack
* Seq::Config::SparseTrack

=cut

use Moose 2;
use MooseX::Types::Path::Tiny qw/ AbsPath /;

use namespace::autoclean;
use DDP;

extends 'Seq::Tracks';
with 'Seq::Role::Message', 'Seq::Role::ConfigFromFile';

#not sure in the current codebase that it doesn't make more sense to just 
#have the package that needs the variable to declare it as has

# state $_attributesAref = \qw/ genome_name genome_description genome_chrs genome_index_dir
#    debug wanted_chr debug force act/;

has genome_name        => ( is => 'ro', isa => 'Str', required => 1, );
has genome_description => ( is => 'ro', isa => 'Str', required => 1, );

=property @public {Str} database_dir

  The path (relative or absolute) to the index folder, which contains all databases

  Defined in the required input yaml config file, as a key : value pair, and
  used by:
  @role Seq::Role::ConfigFromFile

  The existance of this directory is checked in Seq::Annotate::BUILDARGS

@example database_dir: hg38/index
=cut

has messanger => (
  is => 'ro',
  isa => 'HashRef',
  default => sub{ {} },
);

has publisherAddress => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => sub{ [] },
);

#moved all track handling to Tracks.pm

has debug => (
  is      => 'ro',
  isa     => 'Int',
  default => 0,
);

#set up singleton stuff
sub BUILD {
  my $self = shift;
  
  if(%{$self->messanger} && @{$self->publisherAddress} ) {
    #p $self;
    $self->setPublisher($self->messanger, $self->publisherAddress);
  }
}

__PACKAGE__->meta->make_immutable;

1;

# not sure of the value of this in the new schema
# sub BUILDARGS {
#   my $class = shift;
#   my $href  = $_[0];

#   if ( scalar @_ > 1 || reftype($href) ne "HASH" ) {
#     confess "Error: $class expects hash reference.\n";
#   }
#   else {
#     my %hash;
    
#     #don't want to use a default directory, because user needs to have 
#     #hundreds of gigs available for a single 

#     #not sure of the overall utility of making assembly control this
#     #since it introduces maintenance overhead; we need to keep track 
#     #of what each package needs here
#     # for my $attrib (@$_attributesAref) {
#     #   $hash{$attrib} = $href->{$attrib} if exists $href->{$attrib};
#     # }
#     # #allows mixins to get attributes without making subclasses
#     # #avoid knowitall antipatterns (defeat purpose of encapsulation in mixins)
#     # for my $key ( keys %$href ) {
#     #   next if exists $hash{$key};
#     #   $hash{$key} = $href->{$key};
#     # }

#     #all packages are responsible for declaring what they need
#     #anything that is set as required and isn't given causes errors
#     return $class->SUPER::BUILDARGS( $href );
#   }
# }

# has genome_chrs => (
#   is       => 'ro',
#   isa      => 'ArrayRef[Str]',
#   traits   => ['Array'],
#   required => 1,
#   handles  => { all_genome_chrs => 'elements', },
# );

# has genome_sized_tracks => (
#   is      => 'ro',
#   isa     => 'ArrayRef[Seq::Config::GenomeSizedTrack]',
#   traits  => ['Array'],
#   handles => {
#     all_genome_sized_tracks => 'elements',
#     add_genome_sized_track  => 'push',
#   },
# );
# has snp_tracks => (
#   is      => 'ro',
#   isa     => 'ArrayRef[Seq::Config::SparseTrack]',
#   traits  => ['Array'],
#   handles => {
#     all_snp_tracks => 'elements',
#     add_snp_track  => 'push',
#   },
# );
# has gene_tracks => (
#   is      => 'ro',
#   isa     => 'ArrayRef[Seq::Config::SparseTrack]',
#   traits  => ['Array'],
#   handles => {
#     all_gene_tracks => 'elements',
#     add_gene_track  => 'push',
#   },
# );

# if ( $href->{debug} ) {
    #   my $msg =
    #     sprintf( "genome_index_dir: %s", $href->{genome_index_dir}->absolute->stringify );
    #   say $msg;
    #   $msg = sprintf( "genome_raw_dir: %s", $href->{genome_raw_dir}->absolute->stringify );
    #   say $msg;
    # }

    # for my $sparse_track ( @{ $href->{sparse_tracks} } ) {
    #   # give all sparse tracks some needed information
    #   for my $attr (qw/ genome_raw_dir genome_index_dir genome_chrs /) {
    #     $sparse_track->{$attr} = $href->{$attr};
    #   }

    #   if ( $sparse_track->{type} eq 'gene' ) {
    #     push @{ $hash{gene_tracks} }, Seq::Config::SparseTrack->new($sparse_track);
    #   }
    #   elsif ( $sparse_track->{type} eq 'snp' ) {
    #     push @{ $hash{snp_tracks} }, Seq::Config::SparseTrack->new($sparse_track);
    #   }
    #   else {
    #     croak sprintf( "unrecognized genome track type %s\n", $sparse_track->{type} );
    #   }
    # }

    # for my $gst ( @{ $href->{genome_sized_tracks} } ) {
    #   # give all genome size tracks some needed information
    #   for my $attr (qw/ genome_raw_dir genome_index_dir genome_chrs /) {
    #     $gst->{$attr} = $href->{$attr};
    #   }

    #   if ( $gst->{type} eq 'genome'
    #     or $gst->{type} eq 'score'
    #     or $gst->{type} eq 'ngene'
    #     or $gst->{type} eq 'cadd' )
    #   {
    #     my $obj = Seq::Config::GenomeSizedTrack->new($gst);
    #     push @{ $hash{genome_sized_tracks} }, $obj;
    #   }
    #   else {
    #     croak sprintf( "unrecognized genome track type %s\n", $gst->{type} );
    #   }
    # }
