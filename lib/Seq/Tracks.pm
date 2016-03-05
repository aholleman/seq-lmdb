use 5.10.0;
use strict;
use warnings;

package Seq::Config::Track;

our $VERSION = '0.001';

# ABSTRACT: A base class for track classes
# VERSION

use Moose 2;
use Moose::Util::TypeConstraints; 
use namespace::autoclean;
use Path::Tiny;
use MooseX::Types::Path::Tiny qw/Path/;

with 'Seq::Role::Messages', 'Seq::Tracks::Definition';

=property @public @required {Str} name

  The track name. This is defined directly in the input config file.

  @example:
  =for :list
  * gene
  * snp

=cut

has dataTracks =>(
  is => 'ro',
  isa => 'HashRef[ArrayRef]',
  lazy => 1,
  builder => '_buildDataTracks',
  traits => ['Hash'],
  handles => {
    getDataTracks => 'get',
  }
);

#qw/allGeneTracks allSnpTracks allRegionTracks allScoreTracks
#  allSparseTracks refTrack ngeneTrack/,
# coming from config file
# expects: {
# typeName : {
#  name: someName (optional),
#  data: {
#   feature1:   
#}  
#}
#}
has tracks => (
  is => 'ro',
  isa => 'ArrayRef[HashRef]',
  required => 1,
);

# used to simplify process of detecting tracks
# I think that Tracks.pm should know which features it has access to
# and anything conforming to that interface should become an instance
# of the appropriate class
# and everythign else shouldn't, and should generate a warning
# This is heavily inspired by Dr. Thomas Wingo's primer picking software design
# expects structure to be {
#  trackName : {typeStuff},
#  typeName2 : {typeStuff2},
#}

#We don't instantiate a new object for each data source
#Instead, we simply create a container for each name : type pair
#We could use an array, but a hash is easier to reason about
#We also expect that each record will be identified by its track name
#so (in db) {
#   trackName : {
#     featureName: featureValue  
#} 
#}
sub _buildDataTracks {
  my $self = shift;

  my %out;
  for my $trackHref (@{$self->tracks}) {
    my $trackClass = $self->getBuilder($trackHref->{type} );
    if(!$trackClass) {
      $self->tee_logger('warn', "Invalid track type $trackHref->{type}");
      next;
    }
    if(exists $out{$trackHref->{name} } ) {
      $self->tee_logger('warn', "More than one track with the same name 
        exists: $trackHref->{name}. Each track name must be unique
      . Overriding the last object for this name, with the new")
    }
    $out{$trackHref->{name} } = $trackClass->new($trackHref);
    #push @{$out{$trackHref->{type} } }, $trackClass->new($trackHref);
  }
  return \%out;
}

#@param $data: {
# type : {
#  name: someName (optional),
#  data: {
#   feature1:   
#}  
#}
#}
sub getAllDataAsHref {

}
#Not certain if this is needed yet; if it is we should keep track of types
#all* returns array ref
# sub allSnpTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->snpType};
# }

# sub allRegionTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->regionType};
# }

# sub allScoreTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->scoreType};
# }

# sub allSparseTracks {
#   my $self = shift;
#   return $self->dataTracks->{$self->sparseType};
# }

# #returns hashRef; only one of the following tracks is allowed
# sub refTrack {
#   my $self = shift;
#   return $self->dataTracks->{$self->refType}[0];
# }

# #we could think about relaxing this constraint.
# #in that case, we should couple ngene and gene tracks as one type
# sub geneTrack {
#   my $self = shift;
#   return $self->dataTracks->{$self->geneType};
# }

#this has been coupled to gene
# sub ngeneTrack {
#   my $self = shift;
#   return $self->dataTracks->{$self->ngeneType}[0];
# }

=method all_genome_chrs

  Returns all of the elements of the @property {ArrayRef<str>} C<genome_chrs>
  as an array (not an array reference).
  $self->all_genome_chrs

=cut



# used to simplify process of detecting tracks
# I think that Tracks.pm should know which features it has access to
# and anything conforming to that interface should become an instance
# of the appropriate class
# and everythign else shouldn't, and should generate a warning
# This is heavily inspired by Dr. Thomas Wingo's primer picking software design
# expects structure to be {
#  trackName : {typeStuff},
#  typeName2 : {typeStuff2},
#}
sub insantiateTracks {
  my ( $self, $href ) = @_;

  my @out;
  for my $maybeTrackType (keys %$href) {
    if(!$trackMap->{$maybeTrackType} ) {
      $self->tee_logger('warn', "Invalid track type $maybeTrackType");
      next;
    }
    push @out, $trackMap->{$maybeTrackType}->new( data => $href->{$maybeTrackType} );
  }
}

# sub insantiateRef {
#   my ( $self, $href ) = @_;

#   for my $maybeTrackType (keys %$href) {
#     if($maybeTrackType eq $refType) {
#       return $trackMap->{$refType}->new($href)
#     }
#   }
# }

# sub insantiateSparse {
#   my ( $self, $href ) = @_;

#   my @out;
#   for my $maybeTrackType (keys %$href) {
#     if($maybeTrackType eq $refType) {
#       return $trackMap->{$spareType}->new($href)
#     }
#   }
# }

__PACKAGE__->meta->make_immutable;

1;
