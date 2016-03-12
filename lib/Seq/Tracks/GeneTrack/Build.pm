use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::GeneTrack::Build;

our $VERSION = '0.001';

# ABSTRACT: Builds Gene Tracks 
    # Takes care of gene_db, transcript_db, and ngene from the previous Seqant version
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Build::GeneTrack>

  TODO: Describe

Used in:

=for :list
* Seq::Build:
* Seq::Config::SparseTrack
    The base class for building, annotating sparse track features.
    Used by @class Seq::Build
    Extended by @class Seq::Build::SparseTrack, @class Seq::Fetch::Sql,

Extended in: None

=cut

use Moose 2;

use File::Path qw/ make_path /;
use File::Spec;
use namespace::autoclean;

use Seq::Tracks::GeneTrack::Build;

use Data::Dump qw/dump/;

extends 'Seq::Tracks::SparseTrack::Build';
with 'Seq::Role::IO';

state $requiredFields = \qw( chrom     strand    txStart   txEnd
  cdsStart  cdsEnd    exonCount exonStarts
  exonEnds  name );

# has '+requiredFields' => (
#   is      => 'ro',
#   isa     => 'ArrayRef',
#   init_arg => undef,
#   lazy => 1,
#   builder => '_buildRequiredFields',
# );

# sub _buildRequiredFields {
#   my $self = shift;

#   my @out;
#   push @out, @{$requiredFields}, @{$self->features};
#   return \@out;
# }

sub _get_gene_data {
  #TODO
  # my ( $self, $wanted_chr ) = @_;

  # # to return gene data
  # my @gene_data;

  # my $msg = sprintf( "build gene site db (chr: %s): start", ( $wanted_chr || 'all' ) );
  # $self->_logger->info($msg);

  # # input files
  # my @input_files = $self->all_local_files;

  # my %ucsc_table_lu = (
  #   name       => 'transcript_id',
  #   chrom      => 'chr',
  #   cdsEnd     => 'coding_end',
  #   cdsStart   => 'coding_start',
  #   exonEnds   => 'exon_ends',
  #   exonStarts => 'exon_starts',
  #   strand     => 'strand',
  #   txEnd      => 'transcript_end',
  #   txStart    => 'transcript_start',
  # );
  # my ( %header, %transcript_start_sites );

  # for my $input_file (@input_files) {
  #   # check file
  #   if ( !-s $input_file ) {
  #     my $msg = sprintf( "ERROR: expected file is empty or missing, %s", $input_file );
  #     $self->_logger->error($msg);
  #     say $msg;
  #     exit(1);
  #   }
  #   my $in_fh = $self->get_read_fh($input_file);
  #   while ( my $line = $in_fh->getline ) {
  #     chomp $line;
  #     my @fields = split( /\t/, $line );
  #     if ( !%header ) {

  #       %header = map { $fields[$_] => $_ } ( 0 .. $#fields );

  #       # do we have the required keys?
  #       $self->_check_header_keys( \%header, [ keys %ucsc_table_lu ] );

  #       # do we have the optinally specified keys?
  #       $self->_check_header_keys( \%header, [ $self->all_features ] );
  #       next;
  #     }
  #     my %data = map { $_ => $fields[ $header{$_} ] }
  #       ( @{ $self->gene_fields_aref }, $self->all_features );

  #     if ($wanted_chr) {
  #       next unless $data{chrom} eq $wanted_chr;
  #     }
  #     else {
  #       # skip unassigned or alternative chromosomes
  #       next unless grep { /\A$data{chrom}\z/xms } $self->all_genome_chrs;
  #     }

  #     # prepare basic gene data
  #     my %gene_data = map { $ucsc_table_lu{$_} => $data{$_} } keys %ucsc_table_lu;
  #     $gene_data{exon_ends}   = [ split( /\,/, $gene_data{exon_ends} ) ];
  #     $gene_data{exon_starts} = [ split( /\,/, $gene_data{exon_starts} ) ];
  #     $gene_data{genome_track} = $self->genome_str_track;

  #     # prepare alternative names for gene
  #     #   - the basic problem is that the type constraint on alt_names wants
  #     #   the hash to contain strings; without the ($data{$_}) ? $data{$_} : 'NA'
  #     #   there were some keys with blank values
  #     #   - this feels like a hack to accomidate the type constraint on alt_names
  #     #   attributes and will increase the db size; may just drop the keys without
  #     #   data in the future but it's running now so will hold off for the time
  #     #   being.
  #     my %alt_names = map { $_ => ( $data{$_} ) ? $data{$_} : 'NA' if exists $data{$_} }
  #       ( $self->all_features );
  #     $gene_data{_alt_names} = \%alt_names;

  #     push @gene_data, \%gene_data;
  #   }
  # }
  # return \@gene_data;
}

# build_tx_db_for_genome takes the genome length, the
sub build_tx_db_for_genome {
  #TODO
  # my ( $self, $genome_length ) = @_;

  # # read gene data for the chromosome
  # #   if there is no usable data then we will bail out and no blank files
  # #   will be created
  # my $chr_data_aref = $self->_get_gene_data();
  # $self->_logger->info("finished reading data for all chromosomes");

  # # prepare output dir, as needed
  # $self->genome_index_dir->mkpath unless ( -d $self->genome_index_dir );

  # # $gene region site range file
  # my $gene_region_file = $self->get_dat_file( 'genome', 'tx' );
  # my $msg = sprintf( "writing to: '%s'", $gene_region_file );
  # $self->_logger->info($msg);

  # # tx dbm file
  # my $tx_dbm_file = $self->get_kch_file( 'genome', 'tx' );
  # $msg = sprintf( "writing to: '%s'", $tx_dbm_file );
  # $self->_logger->info($msg);

  # # nearest neighbor dbm file
  # my $nn_dbm_file = $self->get_kch_file( 'genome', 'gene' );
  # $msg = sprintf( "writing to: '%s'", $nn_dbm_file );
  # $self->_logger->info($msg);

  # # nearest neighbor region file
  # my $nn_region_file = $self->get_dat_file( 'genome', 'gene' );
  # $msg = sprintf( "writing to: '%s'", $nn_region_file );
  # $self->_logger->info($msg);

  # # check if we've already build site range files unless forced to overwrite
  # unless ( $self->force ) {
  #   if ( $self->_has_site_range_file($gene_region_file) ) {
  #     return $nn_region_file;
  #   }
  # }

  # # write header for region file
  # my $gene_region_fh = $self->get_write_fh($gene_region_file);
  # say {$gene_region_fh} $self->in_gene_val;

  # # create dbm object for transcripts
  # # my $db_tx = Seq::KCManager->new(
  # #   filename => $tx_dbm_file,
  # #   mode     => 'create',
  # #   # bnum => bucket number => 50-400% of expected items in the hash is optimal
  # #   # annotated sites for hg38 is 22727477 (chr1) to 13222 (chrM) with avg of
  # #   # 9060664 and sd of 4925631; thus, took ~1/2 of maximal number of entries
  # #   bnum => 1_000_000,
  # #   msiz => 512_000_000,
  # # );

  # # create dbm object for nearest neighbor gene list
  # # my $db_nn = Seq::KCManager->new(
  # #   filename => $nn_dbm_file,
  # #   mode     => 'create',
  # #   # bnum => bucket number => 50-400% of expected items in the hash is optimal
  # #   # about ~5000 genes per chromosome
  # #   bnum => 2_500,
  # #   msiz => 512_000_000,
  # # );

  # my $gene_number = 1;
  # my ( %chr_for_gene, %txStartStop, %txGeneToNum );

  # for my $gene_href (@$chr_data_aref) {
  #   my $gene = Seq::Gene->new($gene_href);
  #   $gene->set_alt_names( %{ $gene_href->{_alt_names} } );
  #   my $record_href = {
  #     coding_start            => $gene->coding_start,
  #     coding_end              => $gene->coding_end,
  #     exon_starts             => $gene->exon_starts,
  #     exon_ends               => $gene->exon_ends,
  #     peptide_seq             => $gene->peptide,
  #     strand                  => $gene->strand,
  #     transcript_start        => $gene->transcript_start,
  #     transcript_end          => $gene->transcript_end,
  #     transcript_id           => $gene->transcript_id,
  #     transcript_seq          => $gene->transcript_seq,
  #     transcript_annotation   => $gene->transcript_annotation,
  #     transcript_abs_position => $gene->transcript_abs_position,
  #   };

  #   # save gene attr in dbm
  #   $self->db_put( $record_href->{transcript_id}, $record_href );

  #   # save tx start/stop for gene
  #   say {$gene_region_fh} join "\t", $gene->transcript_start, $gene->transcript_end;

  #   # prefer to keep the geneSymbol since there are < 30K (in humans); for
  #   #   organisms without geneSymbol we'll store transcript_id
  #   my $gene_name = $gene_href->{_alt_names}{geneSymbol} or $gene->transcript_id;

  #   # there are certain gene symbols, primarily provisional ones, that are re-used
  #   #   this causes some problems since they are often on different chromosomes;
  #   #   it should be obvious that we'll only capture the 1st gene symbol for any
  #   #   repeats
  #   if ( exists $chr_for_gene{$gene_name} ) {
  #     if ( $gene->chr ne $chr_for_gene{$gene_name} ) {
  #       next;
  #     }
  #   }
  #   else {
  #     $chr_for_gene{$gene_name} = $gene->chr;
  #   }

  #   # - skip entries wihout a gene symbol, which will default to 'NA'
  #   # - skip entries that are non-coding (many of these have duplicate names,
  #   #   often appearing on the same chromosome, which makes things weird).
  #   if ( $gene_name eq "NA" || ( $gene->coding_start == $gene->coding_end ) ) {
  #     next;
  #   }

  #   if ( exists $txStartStop{$gene_name} ) {
  #     my ( $start, $end ) = @{ $txStartStop{$gene_name} };
  #     if ( $gene->transcript_start < $start ) {
  #       $start = $gene->transcript_start;
  #     }
  #     if ( $gene->transcript_end > $end ) {
  #       $end = $gene->transcript_end;
  #     }
  #     $txStartStop{$gene_name} = [ $start, $end ];
  #   }
  #   else {
  #     $txStartStop{$gene_name} = [ $gene->transcript_start, $gene->transcript_end ];
  #     $txGeneToNum{$gene_name} = $gene_number;
  #     $gene_number++;
  #   }

  #   $msg = sprintf(
  #     "gene: %s (%d), start: %s, stop %s",
  #     $gene_name,
  #     $txGeneToNum{$gene_name},
  #     $txStartStop{$gene_name}[0],
  #     $txStartStop{$gene_name}[1]
  #   );
  #   $self->_logger->info($msg);

  # }

  # # now, the helper program will sort this so it's not strictly necessary to do so here
  # my @sorted_genes = map { $_->[0] }
  #   sort { $a->[1] <=> $b->[1] }
  #   map { [ $_, $txStartStop{$_}->[0] ] } ( keys %txStartStop );

  # # write data
  # #   1) dat file => ngene idx
  # #   2) kch for ngene db lookup
  # my $regionFh = IO::File->new( $nn_region_file, 'w' ) || die "$!";

  # # might just make this a command line argument
  # say {$regionFh} $genome_length;

  # for my $gene (@sorted_genes) {

  #   # save in dat file for ngene idx helper program
  #   say {$regionFh} join "\t", $gene, $txGeneToNum{$gene}, @{ $txStartStop{$gene} };

  #   # kch save gene number and name
  #   $db_nn->db_put_string( $txGeneToNum{$gene}, $gene );
  # }
  # close($regionFh);

  # $msg = sprintf(
  #   "genes: %d; first gene: %s, last gene: %s",
  #   ( scalar @sorted_genes ),
  #   $sorted_genes[0], $sorted_genes[$#sorted_genes]
  # );
  # $self->_logger->info($msg);
  # return $nn_region_file;
}

sub build_gene_db_for_chr {
  #TODO
  # my ( $self, $wanted_chr ) = @_;

  # # read gene data for the chromosome
  # #   if there is no usable data then we will bail out and no blank files
  # #   will be created
  # my $chr_data_aref = $self->_get_gene_data($wanted_chr);
  # $self->_logger->info("finished reading data for $wanted_chr");

  # # prepare output dir, as needed
  # $self->genome_index_dir->mkpath unless ( -d $self->genome_index_dir );

  # # flanking site range file
  # my $gan_file = $self->get_dat_file( $wanted_chr, 'gan' );
  # my $msg = sprintf( "writing to: '%s'", $gan_file );
  # $self->_logger->info($msg);

  # # exon site range file
  # my $ex_file = $self->get_dat_file( $wanted_chr, 'exon' );
  # $msg = sprintf( "writing to: '%s'", $ex_file );
  # $self->_logger->info($msg);

  # # dbm file
  # my $dbm_file = $self->get_kch_file($wanted_chr);
  # $msg = sprintf( "writing to: '%s'", $dbm_file );
  # $self->_logger->info($msg);

  # # check if we've already build site range files unless forced to overwrite
  # unless ( $self->force ) {
  #   return
  #     if ( $self->_has_site_range_file($gan_file)
  #     && $self->_has_site_range_file($ex_file) );
  # }

  # my $db = Seq::KCManager->new(
  #   filename => $dbm_file,
  #   mode     => 'create',
  #   # bnum => bucket number => 50-400% of expected items in the hash is optimal
  #   # annotated sites for hg38 is 22727477 (chr1) to 13222 (chrM) with avg of
  #   # 9060664 and sd of 4925631; thus, took ~1/2 of maximal number of entries
  #   bnum => 12_000_000,
  #   msiz => 512_000_000,
  # );

  # # write header for region file
  # # NOTE: 1st line needs to be value that should be added to encoded genome for
  # #       the sites listed in the file
  # my $gan_fh = $self->get_write_fh($gan_file);
  # say {$gan_fh} $self->in_gan_val;
  # my $ex_fh = $self->get_write_fh($ex_file);
  # say {$ex_fh} $self->in_exon_val;

  # for my $gene_href (@$chr_data_aref) {
  #   my $gene = Seq::Gene->new($gene_href);
  #   $gene->set_alt_names( %{ $gene_href->{_alt_names} } );

  #   my ( @fl_sites, @ex_sites ) = ();

  #   # get intronic flanking site annotations
  #   my @flank_exon_sites = $gene->all_flanking_sites;
  #   for my $site (@flank_exon_sites) {
  #     my $site_href = $site->as_href;
  #     my $abs_pos   = $site_href->{abs_pos};
  #     $db->db_put( $abs_pos, $site_href );
  #     push @fl_sites, $abs_pos;
  #   }

  #   # flanking sites need only be written to gan file
  #   say {$gan_fh} join "\n", @{ $self->_get_range_list( \@fl_sites ) } if @fl_sites;

  #   # get exon annotations
  #   my @exon_sites = $gene->all_transcript_sites;
  #   for my $site (@exon_sites) {
  #     my $site_href = $site->as_href;
  #     my $abs_pos   = $site_href->{abs_pos};
  #     $db->db_put( $abs_pos, $site_href );
  #     push @ex_sites, $abs_pos;
  #   }

  #   # exonic annotations need to be written to both gan and exon files
  #   say {$ex_fh} join "\n",  @{ $self->_get_range_list( \@ex_sites ) };
  #   say {$gan_fh} join "\n", @{ $self->_get_range_list( \@ex_sites ) };
  # }

  # # - add a final blank line to the region file; this is a bit of a hack so
  # # the c hasher will not crash if there are no entries (after the initial
  # # idx mask)
  # print {$ex_fh} "\n";
  # print {$gan_fh} "\n";

  # $self->_logger->info("finished building gene site for $wanted_chr");
}

__PACKAGE__->meta->make_immutable;

1;
