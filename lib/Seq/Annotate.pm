use 5.10.0;
use strict;
use warnings;

package Seq::Annotate;

# ABSTRACT: Builds a plain text genome used for binary genome creation
# VERSION

use Moose 2;
use Moose;
with 'Seq::Role::ConfigFromFile';
use Carp qw/ croak /;
use Path::Tiny qw/ path /;
use namespace::autoclean;
use Scalar::Util qw/ reftype /;
use Type::Params qw/ compile /;
use Types::Standard qw/ :types /;
use YAML::XS qw/ LoadFile /;

use DDP;

use Seq::GenomeSizedTrackChar;
use Seq::MongoManager;
use Seq::KCManager;
use Seq::Site::Annotation;
use Seq::Site::Snp;

extends 'Seq::Assembly';
with 'Seq::Role::IO', 'MooX::Role::Logger';

has genome_index_dir => (
  is       => 'ro',
  isa      => 'Str',
  required => 1
);

has _genome => (
  is       => 'ro',
  isa      => 'Seq::GenomeSizedTrackChar',
  required => 1,
  lazy     => 1,
  builder  => '_load_genome',
  handles  => [
    'get_abs_pos',  'char_genome_length', 'genome_length',   'get_base',
    'get_idx_base', 'get_idx_in_gan',     'get_idx_in_gene', 'get_idx_in_exon',
    'get_idx_in_snp', 'chr_len', 'next_chr',
  ]
);

has _genome_scores => (
  is      => 'ro',
  isa     => 'ArrayRef[Seq::GenomeSizedTrackChar]',
  traits  => ['Array'],
  handles => {
    _all_genome_scores  => 'elements',
    count_genome_scores => 'count',
  },
  lazy    => 1,
  builder => '_load_scores',
);

has _mongo_connection => (
  is      => 'ro',
  isa     => 'Seq::MongoManager',
  lazy    => 1,
  builder => '_build_mongo_connection',
);

has dbm_gene => (
  is      => 'ro',
  isa     => 'ArrayRef[ArrayRef[Seq::KCManager]]',
  builder => '_build_dbm_gene',
  traits  => ['Array'],
  handles => { _all_dbm_gene => 'elements', },
  lazy    => 1,
);

has dbm_snp => (
  is      => 'ro',
  isa     => 'ArrayRef[ArrayRef[Seq::KCManager]]',
  builder => '_build_dbm_snp',
  traits  => ['Array'],
  handles => { _all_dbm_snp => 'elements', },
  lazy    => 1,
);

has dbm_tx => (
  is      => 'ro',
  isa     => 'ArrayRef[ArrayRef[Seq::KCManager]]',
  builder => '_build_dbm_tx',
  traits  => ['Array'],
  handles => { _all_dbm_seq => 'elements', },
  lazy    => 1,
);

has _header => (
  is      => 'ro',
  isa     => 'ArrayRef',
  lazy    => 1,
  builder => '_build_header',
  traits  => ['Array'],
  handles => { all_header => 'elements' },
);

sub _get_dbm_file {

  my ( $self, $name ) = @_;
  my $file = path($self->genome_index_dir, $name )->stringify;

  warn "WARNING: expected file: '$file' does not exist." unless -f $file;
  warn "WARNING: expected file: '$file' is empty." unless $file;

  if (!$file or !-f $file) {
    $self->_logger->warn( "dbm file is either zero-sized or missing: " . $file )
  }
  else {
    $self->_logger->info( "found dbm file: " . $file );
  }

  return $file;
}

sub _build_dbm_gene {
  my $self  = shift;
  my @gene_tracks = ();
  for my $gene_track ( $self->all_gene_tracks ) {
    my @array;
    for my $chr ( $self->all_genome_chrs ) {
      my $db_name = join ".", $gene_track->name, $chr, $gene_track->type, 'kch';
      push @array, Seq::KCManager->new( {
        filename => $self->_get_dbm_file($db_name),
        mode => 'read',
        }
      );
    }
    push @gene_tracks, \@array;
  }
  return \@gene_tracks;
}

sub _build_dbm_snp {
  my $self  = shift;
  my @snp_tracks;
  for my $snp_track ( $self->all_snp_tracks ) {
    my @array = ();
    for my $chr ( $self->all_genome_chrs ) {
      my $db_name = join ".", $snp_track->name, $chr, $snp_track->type, 'kch';
      push @array, Seq::KCManager->new( {
        filename => $self->_get_dbm_file($db_name),
        mode => 'read',
        }
      );
    }
    push @snp_tracks, \@array;
  }
  return \@snp_tracks;
}

sub _build_dbm_tx {
  my $self  = shift;
  my @array = ();
  for my $gene_track ( $self->all_snp_tracks ) {
    my $db_name = join ".", $gene_track->name, $gene_track->type, 'seq', 'kch';
    push @array, Seq::KCManager->new( {
      filename => $self->_get_dbm_file($db_name),
      mode => 'read',
      }
    );
  }
  return \@array;
}

sub _load_genome {
  my $self = shift;

  for my $gst ( $self->all_genome_sized_tracks )
  {
    if ( $gst->type eq 'genome' )
    {
      return $self->_load_genome_sized_track($gst);
    }
  }
}

sub _load_scores {
  my $self = shift;
  my @score_tracks;

  for my $gst ( $self->all_genome_sized_tracks )
  {
    if ( $gst->type eq 'score' )
    {
      push @score_tracks, $self->_load_genome_sized_track($gst);
    }
  }
  return \@score_tracks;
}

sub BUILD {
  my $self = shift;
  #not really? occurs later in _load_genome_sized_track?
  $self->_logger->info( "finished loading genome of size " . $self->genome_length );
  $self->_logger->info(
    "finished loading " . $self->count_genome_scores . " genome score track(s)" );
}

sub _load_genome_sized_track {
  my ( $self, $gst ) = @_;

  # index dir
  my $index_dir = $self->genome_index_dir;

  # alex's new stuff:
  # my $genome_idx_Aref = $self->load_genome_sequence( $idx_name, $idx_dir );
  # temporarily reverting to how I wrote this before.

  # idx file
  my $idx_name = join( ".", $gst->name, $gst->type, 'idx' );
  my $idx_file = File::Spec->catfile( $index_dir, $idx_name );
  my $idx_fh = $self->get_read_fh($idx_file);
  binmode $idx_fh;

  # read genome
  my $seq           = '';
  my $genome_length = -s $idx_file;

  # error check the idx_file
  croak "ERROR: expected file: '$idx_file' does not exist." unless -f $idx_file;
  croak "ERROR: expected file: '$idx_file' is empty." unless $genome_length;

  read $idx_fh, $seq, $genome_length;

  # yml file
  my $yml_name = join( ".", $gst->name, $gst->type, 'yml' );
  my $yml_file = File::Spec->catfile( $index_dir, $yml_name );

  # my $genome_idx_Aref = $self->load_track_data($idx_name, $idx_dir);
  #
  # # yml file
  # my $yml_name = join( ".", $gst->name, $gst->type, 'yml' );
  # my $yml_file_path = path($idx_dir, $yml_name )->stringify;

  # read yml chr offsets
  my $chr_len_href = LoadFile($yml_file);

  my $obj = Seq::GenomeSizedTrackChar->new(
    {
      name          => $gst->name,
      type          => $gst->type,
      genome_chrs   => $self->genome_chrs,
      genome_length => $genome_length,
      chr_len       => $chr_len_href,
      char_seq      => \$seq,
    }
  );

  $self->_logger->info(
    "read genome-sized track (" . $genome_length . ") from $idx_name" );
  return $obj;
}

sub get_ref_annotation {
  state $check = compile( Object, Int, Int );
  my ( $self, $chr_index, $abs_pos ) = $check->(@_);

  my %record;

  my $site_code = $self->get_base($abs_pos);
  my $base      = $self->get_idx_base($site_code);
  my $gan       = ( $self->get_idx_in_gan($site_code) ) ? 1 : 0;
  my $gene      = ( $self->get_idx_in_gene($site_code) ) ? 1 : 0;
  my $exon      = ( $self->get_idx_in_exon($site_code) ) ? 1 : 0;
  my $snp       = ( $self->get_idx_in_snp($site_code) ) ? 1 : 0;

  $record{abs_pos}   = $abs_pos;
  $record{site_code} = $site_code;
  $record{ref_base}  = $base;

  if ($gene) {
    if ($exon) {
      $record{genomic_annotation_code} = 'Exonic';
    }
    else {
      $record{genomic_annotation_code} = 'Intronic';
    }
  }
  else {
    $record{genomic_annotation_code} = 'Intergenic';
  }

  my ( @gene_data, @snp_data, %conserv_scores );

  for my $gs ( $self->_all_genome_scores ) {
    my $name  = $gs->name;
    my $score = $gs->get_score($abs_pos);
    $record{$name} = $score;
    # add CADD stuff here
  }

  for my $gene_dbs ( $self->_all_dbm_gene ) {
    push @gene_data, $gene_dbs->[$chr_index]->db_get($abs_pos);
  }

  for my $snp_dbs ( $self->_all_dbm_snp ) {
    push @snp_data, $snp_dbs->[$chr_index]->db_get($abs_pos);
  }

  $record{gene_data} = \@gene_data if @gene_data;
  $record{snp_data}  = \@snp_data  if @snp_data;

  return \%record;
}

# indels will be handled in a separate method
sub get_snp_annotation {
  state $check = compile( Object, Int, Int, Str );
  my ( $self, $chr_index, $abs_pos, $new_base ) = $check->(@_);

  say "about to get ref annotation: $abs_pos" if $self->debug;

  my $ref_site_annotation = $self->get_ref_annotation($chr_index, $abs_pos);

  p $ref_site_annotation if $self->debug;

  # gene site annotations
  my $gene_aref = $ref_site_annotation->{gene_data};
  my %gene_site_annotation;
  for my $gene_site (@$gene_aref)
  {
    $gene_site->{minor_allele} = $new_base;
    my $gan = Seq::Site::Annotation->new($gene_site)->as_href_with_NAs;
    for my $attr ( keys %$gan )
    {
      if ( exists $gene_site_annotation{$attr} )
      {
        if ( $gene_site_annotation{$attr} ne $gan->{$_} )
        {
          $gene_site_annotation{$attr} =
            $self->_join_data( $gene_site_annotation{$attr}, $gan->{$_} );
        }
      }
      else
      {
        $gene_site_annotation{$attr} = $gan->{$attr};
      }
    }
  }

  # snp site annotation
  my $snp_aref = $ref_site_annotation->{snp_data};
  my %snp_site_annotation;
  for my $snp_site (@$snp_aref)
  {
    my $san = Seq::Site::Snp->new($snp_site)->as_href_with_NAs;
    for my $attr ( keys %$san )
    {
      if ( exists $snp_site_annotation{$attr} )
      {
        if ( $snp_site_annotation{$attr} ne $san->{$attr} )
        {
          $snp_site_annotation{$attr} =
            $self->_join_data( $snp_site_annotation{$attr}, $san->{$attr} );
        }
      }
      else
      {
        $snp_site_annotation{$attr} = $san->{$attr};
      }
    }
  }
  my $record = $ref_site_annotation;
  $record->{gene_site_annotation} = \%gene_site_annotation;
  p %gene_site_annotation if $self->debug;
  $record->{snp_site_annotation} = \%snp_site_annotation;
  p %snp_site_annotation if $self->debug;

  my $gene_ann = $self->_mung_output( \%gene_site_annotation );
  p $gene_ann if $self->debug;
  my $snp_ann = $self->_mung_output( \%snp_site_annotation );
  p $snp_ann if $self->debug;

  map { $record->{$_} = $gene_ann->{$_} } keys %$gene_ann;
  map { $record->{$_} = $snp_ann->{$_} } keys %$snp_ann;

  my @header = $self->all_header;
  my %hash;
  for my $attr (@header)
  {
    if ( $record->{$attr} )
    {
      $hash{$attr} = $record->{$attr};
    }
    else
    {
      $hash{$attr} = 'NA';
    }
  }
  return \%hash;
}

sub _join_data
{
  my ( $self, $old_val, $new_val ) = @_;
  my $type = reftype($old_val);
  if ($type)
  {
    if ( $type eq 'Array' )
    {
      unless ( grep { /$new_val/ } @$old_val )
      {
        push @{$old_val}, $new_val;
        return $old_val;
      }
    }
  }
  else
  {
    my @new_array;
    push @new_array, $old_val, $new_val;
    return \@new_array;
  }
}

sub _mung_output
{
  my ( $self, $href ) = @_;
  my %hash;
  for my $attrib ( keys %$href )
  {
    my $ref = reftype( $href->{$attrib} );
    if ( $ref && $ref eq 'Array' )
    {
      $hash{$attrib} = join( ";", @{ $href->{$attrib} } );
    }
    else
    {
      $hash{$attrib} = $href->{$attrib};
    }
  }
  return \%hash;
}

sub _build_header
{
  my $self = shift;

  my ( %gene_features, %snp_features );

  for my $gene_track ( $self->all_gene_tracks )
  {
    my @features = $gene_track->all_features;
    map { $gene_features{"alt_names.$_"}++ } @features;
  }
  my @alt_features = map { $_ } keys %gene_features;

  for my $snp_track ( $self->all_snp_tracks )
  {
    my @snp_features = $snp_track->all_features;

    # this is a total hack got allow me to calcuate a single MAF for the snp
    # that's not already a value we retrieve and, therefore, doesn't fit in the
    # framework well
    push @snp_features, 'maf';
    map { $snp_features{"snp_feature.$_"}++ } @snp_features;
  }
  map { push @alt_features, $_ } keys %snp_features;

  my @features = qw/ chr pos ref_base genomic_annotation_code annotation_type
    codon_number codon_position error_code minor_allele new_aa_residue new_codon_seq
    ref_aa_residue ref_base ref_codon_seq site_type strand transcript_id snp_id /;

  # add genome score track names
  for my $gs ( $self->_all_genome_scores )
  {
    push @features, $gs->name;
  }

  push @features, @alt_features;

  return \@features;
}

sub annotate_dels
{
  state $check = compile( Object, HashRef );
  my ( $self, $sites_href ) = $check->(@_);
  my ( @annotations, @contiguous_sites, $last_abs_pos );

  # $site_href is defined as %site{ abs_pos } = [ chr, pos ]

  for my $abs_pos ( sort { $a <=> $b } keys %$sites_href )
  {
    if ( $last_abs_pos + 1 == $abs_pos )
    {
      push @contiguous_sites, $abs_pos;
      $last_abs_pos = $abs_pos;
    }
    else
    {
      # annotate site
      my $record = $self->_annotate_del_sites( \@contiguous_sites );

      # arbitrarily assign the 1st del site as the one we'll report
      ( $record->{chr}, $record->{pos} ) = @{ $sites_href->{ $contiguous_sites[0] } };

      # save annotations
      push @annotations, $record;
      @contiguous_sites = ();
    }
  }
  return \@annotations;
}

# data for tx_sites:
# hash{ abs_pos } = (
# coding_start => $gene->coding_start,
# coding_end => $gene->coding_end,
# exon_starts => $gene->exon_starts,
# exon_ends => $gene->exon_ends,
# transcript_start => $gene->transcript_start,
# transcript_end => $gene->transcript_end,
# transcript_id => $gene->transcript_id,
# transcript_seq => $gene->transcript_seq,
# transcript_annotation => $gene->transcript_annotation,
# transcript_abs_position => $gene->transcript_abs_position,
# peptide_seq => $gene->peptide,
# );

sub _annotate_del_sites
{
  state $check = compile( Object, ArrayRef );
  my ( $self, $site_aref ) = $check->(@_);
  my ( @tx_hrefs, @records );

  for my $abs_pos (@$site_aref)
  {
    # get a seq::site::gene record munged with seq::site::snp

    my $record = $self->get_ref_annotation($abs_pos);

    for my $gene_data ( @{ $record->{gene_data} } )
    {
      my $tx_id = $gene_data->{transcript_id};

      for my $dbm_seq ( $self->_all_dbm_seq ) {
        my $tx_href = $dbm_seq->db_get($tx_id);
        if ( defined $tx_href ) {
          push @tx_hrefs, $tx_href;
        }
      }
    }
    for my $tx_href (@tx_hrefs)
    {
      # substring...
    }
  }
}

__PACKAGE__->meta->make_immutable;

1;
