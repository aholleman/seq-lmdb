use 5.10.0;
use strict;
use warnings;

package Seq::Base;

our $VERSION = '0.002';

#All this does is initialize the messaging state, if passed, and extends Seq::Track
#which allows consuming classes to access the tracks.
use Moose 2;
use namespace::autoclean;
extends 'Seq::Tracks';

#Right now this is used to name the log file
#Not sure if this will continue to be used.
#removed genome_description, because assemblies already identify the species
#and becuase it isn't used anywhere in the Seq library
#genome_description (currently the species) has no prupose
has genome_name        => ( is => 'ro', isa => 'Str', required => 1, );

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

has logPath => (
  is => 'ro',
  lazy => 1,
  default => '',
);

#set up singleton stuff
sub BUILD {
  my $self = shift;
  
  if(%{$self->messanger} && @{$self->publisherAddress} ) {
    #p $self;
    $self->setPublisher($self->messanger, $self->publisherAddress);
  }

  if ($self->logPath) {
    $self->setLogPath($self->logPath);
  }

  #todo: finisih ;for now we have only one level
  if ( $self->debug ) {
    $self->setLogLevel('info');
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
