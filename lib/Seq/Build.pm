use 5.10.0;
use strict;
use warnings;

package Seq::Build;

our $VERSION = '0.001';

use DDP;
# ABSTRACT: A class for building all files associated with a genome assembly
# VERSION

=head1 DESCRIPTION

  @class Seq::Build
  #TODO: Check description
  Build the annotation databases, as prescribed by the genome assembly.

  @example

Uses:
=for :list
* @class Seq::Build::SnpTrack
* @class Seq::Build::GeneTrack
* @class Seq::Build::TxTrack
* @class Seq::Build::GenomeSizedTrackStr
* @class Seq::KCManager
* @role Seq::Role::IO

Used in:
=for :list
* /bin/build_genome_assembly.pl

Extended in: None

=cut

use Moose 2;
use namespace::autoclean;

extends 'Seq::Base';

has genome_chrs => (
  is       => 'ro',
  isa      => 'ArrayRef[Str]',
  traits   => ['Array'],
  required => 1,
  handles  => { all_genome_chrs => 'elements', },
);

# #this isn't used yet.
# has wanted_chr => (
#   is      => 'ro',
#   isa     => 'Maybe[Str]',
# );

# comes from Seq::Tracks, which is extended by Seq::Assembly
has wantedType => (
  is => 'ro',
  isa => 'Maybe[TrackType]',
);

# has wantedName => (
#   is => 'ro',
#   isa => 'Maybe[Str]',
# );

#TODO: before building any track other than referebce, 
#check whether the reference track  has finished building.
sub BUILD {
  my $self = shift;

  #$self->log('info', "wanted_chr: " . $self->wanted_chr || 'all' );

  # not working yet
  # if($self->wantedType && $self->wantedName) {
  #   $self->log('error', "can't specify both wantedType and wantedName,
  #     it's ambiguous");
  # }

  my @builders;
  if($self->wantedType) {
    @builders = $self->getBuilders($self->wantedType);
  } else {
    @builders = $self->getAllBuilders();
  }

  if($self->debug) {
    say "requested builders are";
    p @builders;
  }
  
  for my $bTypeAref (@builders) {
    for my $builder (@$bTypeAref) {
      $builder->buildTrack();
      $self->log('debug', "finished building " . $builder->{name} );
    }
  }

  $self->log('debug', "finished building all requested tracks: " 
    . join(@builders, ', ') );
}

# TODO
# sub build_transcript_db {
#   my $self = shift;

#   $self->_logger->info('build transcripts: start');

#   for my $gene_track ( $self->all_gene_tracks ) {

#     my $msg = sprintf( "start gene tx db, '%s'", $gene_track->name );
#     $self->_logger->info($msg) if $self->debug;

#     # extract keys from snp_track for creation of Seq::Build::GeneTrack
#     my $record = $gene_track->as_href;

#     # add required fields for the build track
#     for my $attr (qw/ force debug genome_str_track /) {
#       $record->{$attr} = $self->$attr if $self->$attr;
#     }

#     # add additional keys to the hashref for Seq::Build::TxTrack
#     my $gene_db = Seq::Build::GeneTrack->new($record);

#     my $region_file = $gene_db->build_tx_db_for_genome( $self->genome_length );

#     $msg = sprintf( "finished gene tx db, '%s'", $gene_track->name );
#     $self->_logger->info($msg) if $self->debug;

#     # get genome configuration object
#     #   NOTE: needed for genome_offset_file(), genome_bin_file(), and
#     #         genome_str_file() methods
#     my $ngene_obj;
#     foreach my $gst ( $self->all_genome_sized_tracks ) {
#       if ( $gst->type eq 'ngene' ) {
#         if ( $gene_track->name eq $gst->name ) {
#           $ngene_obj = $gst;
#         }
#       }
#     }

#     # skip if we don't find gene track that has the same name as the ngene
#     #   genome-sized track
#     next unless $ngene_obj;

#     # make chromosome start offsets for binary genome
#     my %chr_len = map { $_ => $self->get_abs_pos( $_, 1 ) } ( $self->all_genome_chrs );

#     # write chromosome offsets
#     my $chr_offset_file = $ngene_obj->genome_offset_file;
#     my $chr_offset_fh   = $self->get_write_fh($chr_offset_file);
#     print {$chr_offset_fh} Dump( \%chr_len );

#     my $cmd = sprintf( "%s -chr %s -gene %s -out %s\n",
#       $self->ngene_bin, $chr_offset_file, $region_file, $ngene_obj->genome_bin_file );

#     $self->_logger->info("running command: $cmd");

#     my $exit_code = system $cmd;

#     if ($exit_code) {
#       my $msg =
#         sprintf( "error encoding genome with %s: %d", $self->ngene_bin, $exit_code );
#       $self->_logger->error($msg);
#       croak $msg;
#     }
#     elsif ( !-f $ngene_obj->genome_bin_file ) {
#       my $msg =
#         sprintf( "ERROR: did not find expected output '%s'", $ngene_obj->genome_bin_file );
#       $self->_logger->error($msg);
#       croak $msg;
#     }
#   }
#   $self->_logger->info('build transcripts: done');
# }

#TODO: move to snp builder track definition
# sub build_snp_sites {
#   my $self = shift;

#   $self->_logger->info('build snp tracks: start');
#   my $wanted_chr = $self->wanted_chr;

#   for my $snp_track ( $self->allSnpTracks ) {

#     # extract keys from snp_track for creation of Seq::Build::SnpTrack
#     my $record = $snp_track->as_href;

#     # add required fields for the build track
#     for my $attr (qw/ force debug genome_str_track /) {
#       $record->{$attr} = $self->$attr if $self->$attr;
#     }

#     for my $chr ( $self->all_genome_chrs ) {

#       # skip to the next chr if we specified a chr to build
#       # and this chr isn't the one we specified
#       if ($wanted_chr) {
#         next unless $wanted_chr eq $chr;
#       }

#       my $msg = sprintf( "snp db, '%s', for chrom '%s': start", $snp_track->name, $chr );
#       $self->_logger->info($msg) if $self->debug;

#       # Seq::Build::SnpTrack needs the string genome
#       my $snp_db = Seq::Build::SnpTrack->new($record);
#       $snp_db->build_snp_db($chr);

#       $msg = sprintf( "snp db, '%s', for chrom '%s': done ", $snp_track->name, $chr );
#       $self->_logger->info($msg) if $self->debug;
#     }
#   }
#   $self->_logger->info('build snp tracks: done');
# }

# now held within Seq::Tracks::GeneTrack::Build
# sub build_gene_sites {
#   my ( $self, $chr ) = @_;

#   $self->_logger->info('build gene track: start');

#   my $wanted_chr = $self->wanted_chr;

#   for my $gene_track ( $self->all_gene_tracks ) {

#     # extract keys from snp_track for creation of Seq::Build::GeneTrack
#     my $record = $gene_track->as_href;

#     # add required fields for the build track
#     for my $attr (qw/ force debug genome_str_track /) {
#       $record->{$attr} = $self->$attr if $self->$attr;
#     }

#     for my $chr ( $self->all_genome_chrs ) {

#       # skip to the next chr if we specified a chr to build and this chr isn't
#       #   the one we specified
#       if ($wanted_chr) {
#         next unless $wanted_chr eq $chr;
#       }

#       my $msg = sprintf( "gene db, '%s', for chrom '%s': start", $gene_track->name, $chr );
#       $self->_logger->info($msg) if $self->debug;

#       # Seq::Build::GeneTrack needs the string genome
#       my $gene_db = Seq::Build::GeneTrack->new($record);
#       $gene_db->build_gene_db_for_chr($chr);

#       $msg = sprintf( "gene db, '%s', for chrom '%s': done", $gene_track->name, $chr );
#       $self->_logger->info($msg) if $self->debug;
#     }
#   }
#   $self->_logger->info('build gene track: done');
# }

# now held within Seq::Tracks::ScoreTrack::Build
# sub build_conserv_scores_index {
#   my $self = shift;

#   $self->_logger->info('build conservation scores: start');

#   # make chr_len hash for binary genome
#   my %chr_len = map { $_ => $self->get_abs_pos( $_, 1 ) } ( $self->all_genome_chrs );

#   # prepare index dir
#   my $index_dir = $self->genome_index_dir->absolute->stringify;
#   $self->genome_index_dir->mkpath unless -f $index_dir;

#   # write conservation scores
#   if ( $self->genome_sized_tracks ) {
#     foreach my $gst ( $self->all_genome_sized_tracks ) {
#       if ( $gst->type eq 'score' ) {

#         # write chromosome offsets
#         my $chr_offset_file = $gst->genome_offset_file;
#         my $chr_offset_fh   = $self->get_write_fh($chr_offset_file);
#         print {$chr_offset_fh} Dump( \%chr_len );

#         # local file
#         my @local_files = $gst->all_local_files;
#         unless ( scalar @local_files == 1 && $local_files[0] =~ m/wigFix/ ) {
#           my $msg = sprintf(
#             "expected 1 local file to build but found %d: %s",
#             scalar @local_files,
#             join( "\t", @local_files )
#           );
#           $self->_logger->error($msg);
#           croak $msg;
#         }

#         # build cmd for external encoder
#         my $cmd = join " ", $self->genome_scorer, $self->genome_length, $chr_offset_file,
#           $local_files[0], $gst->score_max, $gst->score_min, $gst->score_R,
#           $gst->genome_bin_file;

#         $self->_logger->info("running command: $cmd");

#         my $exit_code = system $cmd;

#         if ($exit_code) {
#           my $msg =
#             sprintf( "error encoding genome with %s: %d", $self->genome_scorer, $exit_code );
#           $self->_logger->error($msg);
#           croak $msg;
#         }
#         elsif ( !-f $gst->genome_bin_file ) {
#           my $msg =
#             sprintf( "ERROR: did not find expected output '%s'", $gst->genome_bin_file );
#           $self->_logger->error($msg);
#           croak $msg;
#         }
#       }
#       elsif ( $gst->name eq 'cadd' ) {

#         # write chromosome offsets
#         my $chr_offset_file = $gst->genome_offset_file;
#         my $chr_offset_fh   = $self->get_write_fh($chr_offset_file);
#         print {$chr_offset_fh} Dump( \%chr_len );

#         # local file
#         my @local_files = $gst->all_local_files;

#         # TODO: Do we have to look for "Cadd?" This limits the file name
#         # which is not "Seqant-like" convention over configuration
#         unless ( scalar @local_files == 1 && $local_files[0] =~ m/cadd/ ) {
#           my $msg = sprintf(
#             "expected 1 local file to build but found %d: %s",
#             scalar @local_files,
#             join( "\t", @local_files )
#           );
#           $self->_logger->error($msg);
#           croak $msg;
#         }

#         # build cmd for external encoder
#         my $cmd = join " ", $self->genome_cadd, $self->genome_length, $chr_offset_file,
#           $local_files[0], $gst->score_max, $gst->score_min, $gst->score_R,
#           $gst->genome_bin_file;

#         $self->_logger->info("running command: $cmd");

#         my $exit_code = system $cmd;

#         if ($exit_code) {
#           my $msg =
#             sprintf( "error encoding genome with %s: %d", $self->genome_cadd, $exit_code );
#           $self->_logger->error($msg);
#           croak $msg;
#         }
#         elsif ( !-f $self->genome_bin_file ) {
#           my $msg =
#             sprintf( "ERROR: did not find expected output '%s'", $gst->genome_bin_file );
#           $self->_logger->error($msg);
#           croak $msg;
#         }
#       }
#     }
#     $self->_logger->info('build conservation scores: done');
#   }
# }

# this builds the binary genome that contains in_gene, in_gan, in_snp
# this is no longer necessary in the new version
# now, the GeneTrack will handle these facts, by checking for the associated 
# data stored in an internal hash
#sub build_genome_index {
#   my $self = shift;

#   $self->_logger->info('build indexed genome: start');

#   # build needed tracks, which write ranges for snp and gene sites
#   #   NOTE: if the tracks are built then nothing will be done unless force is
#   #         true in which case the tracks will be rebuilt
#   $self->build_snp_sites;
#   $self->build_gene_sites;
#   $self->build_transcript_db;

#   # prepare index dir
#   my $index_dir = $self->genome_index_dir->absolute->stringify;
#   $self->genome_index_dir->mkpath unless -f $index_dir;

#   # get genome configuration object
#   #   NOTE: needed for genome_offset_file(), genome_bin_file(), and
#   #         genome_str_file() methods
#   my $genome_build_obj;
#   foreach my $gst ( $self->all_genome_sized_tracks ) {
#     if ( $gst->type eq 'genome' ) {
#       $genome_build_obj = $gst;
#     }
#   }

#   # make chromosome start offsets for binary genome
#   my %chr_len = map { $_ => $self->get_abs_pos( $_, 1 ) } ( $self->all_genome_chrs );

#   # write chromosome offsets
#   my $chr_offset_file = $genome_build_obj->genome_offset_file;
#   my $chr_offset_fh   = $self->get_write_fh($chr_offset_file);
#   print {$chr_offset_fh} Dump( \%chr_len );

#   # prepare file that will list all regions to be added
#   my $file_list_name = join( ".", $self->genome_name, 'genome', 'list' );
#   my $region_list_file = File::Spec->catfile( $index_dir, $file_list_name );
#   my $file_list_fh = $self->get_write_fh($region_list_file);

#   my @region_files;

#   $self->_logger->info('build indexed genome: writing file list');

#   # input files for each chr
#   # NOTE: cycle through all snp and gene tracks and combine into one file list
#   #       for genome_hasher
#   for my $chr ( $self->all_genome_chrs ) {

#     # snp sites
#     for my $snp_track ( $self->all_snp_tracks ) {
#       push @region_files, $snp_track->get_dat_file( $chr, $snp_track->type );
#     }

#     # gene annotation and exon positions
#     for my $gene_track ( $self->all_gene_tracks ) {
#       push @region_files, $gene_track->get_dat_file( $chr, 'gan' );
#       push @region_files, $gene_track->get_dat_file( $chr, 'exon' );
#     }
#   }

#   # gather gene region site files
#   for my $gene_track ( $self->all_gene_tracks ) {
#     push @region_files, $gene_track->get_dat_file( 'genome', 'tx' );
#   }

#   # check files in region file exist for genome_hasher
#   for my $file (@region_files) {
#     if ( !-f $file ) {
#       my $msg = sprintf( "ERROR: expected file: '%s' not found", $file );
#       $self->_logger->error($msg);
#       say $msg;
#     }
#   }

#   # write file locations
#   say {$file_list_fh} join "\n", @region_files;

#   my $cmd = join " ", $self->genome_hasher, $genome_build_obj->genome_str_file,
#     $region_list_file, $genome_build_obj->genome_bin_file;

#   $self->_logger->info("running command: $cmd");

#   my $exit_code = system $cmd;

#   if ($exit_code) {
#     my $msg =
#       sprintf( "error encoding genome with %s: %d", $self->genome_cadd, $exit_code );
#     $self->_logger->error($msg);
#     croak $msg;
#   }
#   elsif ( !-f $genome_build_obj->genome_bin_file ) {
#     my $msg =
#       sprintf( "ERROR: did not find expected output '%s'", $self->genome_bin_file );
#     $self->_logger->error($msg);
#     croak $msg;
#   }

#   $self->_logger->info('build indexed genome: done');
#}

__PACKAGE__->meta->make_immutable;

1;
