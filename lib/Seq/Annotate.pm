use 5.10.0;
use strict;
use warnings;

package Seq::Annotate;

our $VERSION = '0.001';

# ABSTRACT: Annotates arbitrary sites of a genome assembly.
# VERSION

=head1 DESCRIPTION Seq::Annotate

  Given a genomic position (and a few other needed pieces) this package
  will provides functions that return annotations for the reference, SNP,
  MULTIALLELIC, INS, and DEL sites.

Used in:

=begin :list
* bin/annotate_ref_site.pl
* bin/read_genome_with_dbs.pl
* @class Seq::Config::GenomeSizedTrack
* @class Seq::Site::Annotation
* @class Seq
  The class which gets called to complete the annotation. Used in:

  =begin :list
  * bin/annotate_snpfile.pl
    Basic command line annotator function. TODO: superceede with Interface.pm
  * bin/annotate_snpfile_socket_server.pl
    Basic socket/multi-core annotator (one annotation instance per core, non-blocking). TODO: superceede w/ Interface.pm
  * bin/redis_queue_server.pl
    Multi-core/process annotation job listener. Spawns Seq jobs
  =end :list
=end :list

Extended in: None

Extends: @class Seq::Assembly

Uses:
=for :list
* @class Seq::GenomeBin
* @class Seq::KCManager
* @class Seq::Site::Annotation
* @class Seq::Site::Gene
* @class Seq::Site::Indel
* @class Seq::Site::SNP
* @class Seq::Site::Snp
* @class Seq::Annotate::Indel;
* @class Seq::Annotate::Site;
* @class Seq::Annotate::Snp;
* @role Seq::Role::IO

=cut

use Moose 2;
use Carp qw/ croak /;
use Path::Tiny qw/ path /;
use namespace::autoclean;
use Scalar::Util qw/ reftype /;
use Type::Params qw/ compile /;
use Types::Standard qw/ :types /;
use YAML::XS qw/ LoadFile /;

use DDP; # for debugging
use Cpanel::JSON::XS;

use Seq::Site::Annotation;
use Seq::Site::Gene;
use Seq::Site::Snp;
use Seq::Site::Indel;
use Seq::Sites::Indels;

use Seq::Annotate::All;
use Seq::Annotate::Snp;
use Seq::Statistics;

extends 'Seq::Assembly';
with 'Seq::Role::IO', 'Seq::Role::DBManager';

=property @private {Seq::GenomeBin<Str>} _genome

  Binary-encoded genome string.

@see @class Seq::GenomeBin
=cut
has statisticsCalculator => (
  is      => 'ro',
  isa     => 'Seq::Statistics',
  handles => {
    recordStat     => 'record',
    summarizeStats => 'summarize',
    statsRecord    => 'statsRecord',
    storeStats     => 'storeStats',
  },
  lazy     => 1,
  required => 1,
  builder  => '_buildStatistics',
);

sub _buildStatistics {
  my $self = shift;
  return Seq::Statistics->new( debug => $self->debug > 2 ? 1 : 0 );
}

has _ngene => (
  is      => 'ro',
  isa     => 'Maybe[Seq::GenomeBin]',
  builder => '_load_ngene',
  lazy    => 1,
  handles => [ 'get_nearest_gene', ],
);

sub _load_ngene {

  my $self = shift;

  for my $gst ( $self->all_genome_sized_tracks ) {
    if ( $gst->type eq 'ngene' ) {
      return $self->_load_genome_sized_track($gst);
    }
  }
  return;
}

# has _genome => (
#   is       => 'ro',
#   isa      => 'Seq::GenomeBin',
#   required => 1,
#   lazy     => 1,
#   builder  => '_load_genome',
#   handles  => [
#     'get_abs_pos',    'char_genome_length', 'genome_length',   'get_base',
#     'get_idx_base',   'get_idx_in_gan',     'get_idx_in_gene', 'get_idx_in_exon',
#     'get_idx_in_snp', 'chr_len',            'next_chr',
#   ]
# );

# NOTE: this is not being used presently;
#   originally thought it might be needed for indel annotations
#has dbm_tx => (
#  is      => 'ro',
#  isa     => 'ArrayRef[Seq::KCManager]',
#  builder => '_build_dbm_tx',
#  traits  => ['Array'],
#  handles => { _all_dbm_tx => 'elements', },
#  lazy    => 1,
#);

has _header => (
  is      => 'ro',
  isa     => 'ArrayRef',
  lazy    => 1,
  builder => '_build_header',
  traits  => ['Array'],
  handles => { all_header => 'elements' },
);

has trackContainers => (
  is => 'ro',
  isa => 'Seq::Tracks',
  required => 1,
);

=property @public {Bool} has_cadd_track

  Records whether or not we have a cadd_track.

=cut

=method set_cadd

  Delegates the Moose "set" method, which Sets the value to 1 and returns 1.

=cut

=method set_cadd

  Delegates the Moose "set" method, which Sets the value of has_cadd_track to 1
  and returns 1.

=cut

=method unset_cadd

  Delegates the Moose "unset" method, which Sets the value of has_cadd_track to
  0 and returns 0.

=cut

has discordant_bases => (
  is      => 'rw',
  isa     => 'Num',
  traits  => ['Counter'],
  handles => { count_discordant => 'inc', }
);

sub BUILD {
  my $self = shift;
  p $self if $self->debug;

  # bulk load all data from GeneTrack once
  # stored in memory, to allow rapid lookups of gene data (range data)
  # without storing the same info in each key within the range
  $self->loadGenes();
}

#TODO: should we uppercase alleles before returning them?
sub _var_alleles {
  my ( $self, $alleles_str, $ref_allele ) = @_;

  return if !$alleles_str || !$ref_allele;

  my ( @snpAlleles, @indelAlleles );

  for my $allele ( split /\,/, $alleles_str ) {
    if ( $allele ne $ref_allele ) {
      if ( length $allele == 1) {
        #skip anything that looks odd; we could also log this, 
        #but could slow us down; haven't benched coro logging
        push @snpAlleles, $allele;
      } else {
        #we could also avoid this and place the indel calling function in annotate
        #into an eval, but this may be slower, althoug here we duplicate concerns
        my $subs = substr($allele, 0, 1);
        if($subs eq '-' || $subs eq '+') {
          push @indelAlleles, $allele;
        } else {
          $self->log('warn', "Allele $allele is unknown");
        }
      }
    }
  }
  return ( \@snpAlleles, \@indelAlleles );
}

# sub _var_alleles_no_indel {
#   my ( $self, $alleles_str, $ref_allele ) = @_;
#   my @var_alleles;

#   for my $allele ( split /\,/, $alleles_str ) {
#     if ( $allele ne $ref_allele
#       && $allele ne 'D'
#       && $allele ne 'E'
#       && $allele ne 'H'
#       && $allele ne 'I'
#       && $allele ne 'N' )
#     {
#       push @var_alleles, $allele;
#     }
#   }
#   return \@var_alleles;
# }

# annotate_snp_site returns a hash reference of the annotation data for a
# given position and variant alleles
sub annotate {
  my (
    $self,       $chr,           $rel_pos,
    $ref_allele, $var_type,      $all_allele_str, $allele_count, $het_ids,
    $hom_ids,    $id_genos_href, $return_obj
  ) = @_;

  my $dataHref = $self->db_get($chr, $rel_pos);

  my $dataTracksHref = $self->insantiateTracks($dataHref);

  my $refData   = $self->getRef($dataHref);
  my $gan       = $self->getGan($site_code);
  my $gene      = $self->inGene($dataHref);
  my $exon      = $self->get_idx_in_exon($site_code);
  my $snp       = $self->get_idx_in_snp($site_code);

  if ( $base ne $ref_allele ) {
    $self->count_discordant;
  }

  my ( $snpAllelesAref, $indelAllelesAref ) =
    $self->_var_alleles( $all_allele_str, $base );

  if ( !( @$snpAllelesAref || @$indelAllelesAref ) ) {
    return;
  }
  my $indelAnnotator;
  if (@$indelAllelesAref) {
    $indelAnnotator = Seq::Sites::Indels->new( alleles => $indelAllelesAref );
  }

  my %record;
  $record{chr} = $chr;
  $record{pos} = $rel_pos;
  #seems to result in NA's currently after as_href
  $record{var_allele}   = join ",", @$snpAllelesAref, @$indelAllelesAref;
  $record{allele_count} = $allele_count;
  $record{alleles}      = $all_allele_str;
  $record{abs_pos}      = $abs_pos;
  $record{var_type}     = $var_type;
  $record{ref_base}     = $base;
  $record{het_ids}      = $het_ids;
  $record{hom_ids}      = $hom_ids;

  if ($gene) {
    if ($exon) {
      $record{genomic_type} = 'Exonic';
    }
    else {
      $record{genomic_type} = 'Intronic';
      if ( $self->_ngene ) {
        my $nearest_gene_code = $self->get_nearest_gene($abs_pos) || '-9';
        if ( $nearest_gene_code != -9 ) {
          $record{nearest_gene} = $self->gene_num_2_str($nearest_gene_code);
        }
      }
      # say STDERR join "\t", $record{genomic_type}, $nearest_gene_code, $record{nearest_gene};
    }
  }
  else {
    $record{genomic_type} = 'Intergenic';
    if ( $self->_ngene ) {
      my $nearest_gene_code = $self->get_nearest_gene($abs_pos) || '-9';
      if ( $nearest_gene_code != -9 ) {
        $record{nearest_gene} = $self->gene_num_2_str($nearest_gene_code);
      }
    }
    # say STDERR join "\t", $record{genomic_type}, $nearest_gene_code, $record{nearest_gene};
  }

  # get scores at site
  for my $gs ( $self->_all_genome_scores ) {
    $record{scores}{ $gs->name } = $gs->get_score($abs_pos);
  }

  if ( @$snpAllelesAref && $self->has_cadd_track ) {
    for my $sAllele (@$snpAllelesAref) {
      $record{scores}{cadd} = $self->get_cadd_score( $abs_pos, $base, $sAllele );
    }
  }

  my ( @gene_data, @snp_data ) = ();

  # get gene annotations at site
  if ($gan) {
    for my $gene_dbs ( $self->_all_dbm_gene ) {
      my $kch = $gene_dbs->[$chr_index];

      # if there's no file for the track then it will be undef
      next unless defined $kch;

      # all kc values come as aref's of href's
      my $rec_aref = $kch->db_get($abs_pos);

      $indelAnnotator->findGeneData( $abs_pos, $kch ) if ($indelAnnotator);

      if ( defined $rec_aref ) {
        for my $rec_href (@$rec_aref) {
          if (@$snpAllelesAref) {
            for my $sAllele (@$snpAllelesAref) {
              $rec_href->{minor_allele} = $sAllele;
              push @gene_data, Seq::Site::Annotation->new($rec_href);
            }
          }
          if ( defined $indelAnnotator ) {
            for my $iAllele ( $indelAnnotator->allAlleles ) {
              $rec_href->{minor_allele}    = $iAllele->minor_allele;
              $rec_href->{annotation_type} = $iAllele->annotation_type;
              push @gene_data, Seq::Site::Indel->new($rec_href);
            }
          }
        }
      }
    }
  }
  $record{gene_data} = \@gene_data;

  # get snp annotations at site
  if ($snp) {
    for my $snp_dbs ( $self->_all_dbm_snp ) {
      my $kch = $snp_dbs->[$chr_index];

      # if there's no file for the track then it will be undef
      next unless defined $kch;

      # all kc values come as aref's of href's
      my $firstBase;
      my $rec_aref = $kch->db_get($abs_pos);
      if ( defined $rec_aref ) {
        for my $rec_href (@$rec_aref) {
          push @snp_data, Seq::Site::Snp->new($rec_href);
        }
      }
    }
  }
  $record{snp_data} = \@snp_data;

  $self->recordStat( $id_genos_href, [ $record{var_type}, $record{genomic_type} ],
    $record{ref_base}, \@gene_data, \@snp_data );
  # create object for href export
  my $obj = Seq::Annotate::All->new( \%record );

  if ( $self->debug ) {
    say "In Annotate.pm::annotate, for these Variants " . $record{var_allele};
    #undef should be fine, if gene_data is an href or something, let's crash
    #so that we can update our expectations
    if ( $self->debug > 1 ) {
      say "We had this record:";
      p $obj;
      if ( @{ $obj->snp_data } ) {
        say "We had this snp_data";
        p $obj->snp_data;
      }
    }
    if ( @{ $obj->gene_data } ) {
      say "We had this gene_data";
      p $obj->gene_data;
    }
  }
  if ($return_obj) {
    return $obj;
  }
  else {
    return $obj->as_href;
  }
}


# NOTE: this is not being used presently;
#   originally thought it might be needed for indel annotations
#sub _build_dbm_tx {
#  my $self = shift;
#  my @array;
#  for my $gene_track ( $self->all_gene_tracks ) {
#    my $dbm = $gene_track->get_kch_file( 'genome', 'tx' );
#    if ( -f $dbm ) {
#      push @array, Seq::KCManager->new( { filename => $dbm, mode => 'read', } );
#    }
#    else {
#      push @array, undef;
#    }
#  }
#  return \@array;
#}

sub _build_header {
  my $self = shift;

  my @features;
  # make Seq::Site::Annotation and Seq::Site::Snp object, and use those to
  # make a Seq::Annotation::Snp object; gather all attributes from those
  # objects, which constitutes the basic header; the remaining pieces will
  # be gathered from the 'scores' and 'gene' and 'snp' tracks that might
  # have various alternative data, depending on the assembly

  # make Seq::Site::Annotation object and add attrs to @features
  my $ann_href = {
    abs_pos   => 10653420,
    alt_names => {
      protAcc     => 'NM_017766',
      mRNA        => 'NM_017766',
      geneSymbol  => 'CASZ1',
      spID        => 'Q86V15',
      rfamAcc     => 'NA',
      description => 'Test',
      kgID        => 'uc001arp.3',
      spDisplayID => 'CASZ1_HUMAN',
      refseq      => 'NM_017766',
    },
    codon_position => 1,
    codon_number   => 879,
    minor_allele   => 'T',
    ref_base       => 'G',
    ref_codon_seq  => 'AGG',
    ref_aa_residue => 'R',
    site_type      => 'Coding',
    strand         => '-',
    transcript_id  => 'NM_017766',
  };
  my $ann_obj       = Seq::Site::Annotation->new($ann_href);
  my $ann_attr_href = $ann_obj->header_attr;

  # make Seq::Site:Snp object and add attrs to @features
  my $snp_href = {
    "abs_pos"     => 10653420,
    "ref_base"    => "G",
    "snp_id"      => "rs123",
    "snp_feature" => {
      "alleleNs"        => "NA",
      "refUCSC"         => "T",
      "alleles"         => "NA",
      "observed"        => "G/T",
      "name"            => "rs123",
      "alleleFreqs"     => "NA",
      "strand"          => "+",
      "func"            => "fake",
      "alleleFreqCount" => 0,
    },
  };
  my $snp_obj       = Seq::Site::Snp->new($snp_href);
  my $snp_attr_href = $snp_obj->header_attr;

  my $annotation_snp_href = {
    chr          => 'chr1',
    pos          => 10653420,
    var_allele   => 'T',
    allele_count => 2,
    alleles      => 'G,T',
    abs_pos      => 10653420,
    var_type     => 'SNP',
    ref_base     => 'G',
    het_ids      => '',
    hom_ids      => 'Sample_3',
    genomic_type => 'Exonic',
    nearest_gene => 'NA',
    scores       => {
      cadd     => 10,
      phyloP   => 3,
      phasCons => 0.9,
    },
    gene_data => [$ann_obj],
    snp_data  => [$snp_obj],
  };
  my $ann_snp_obj       = Seq::Annotate::Snp->new($annotation_snp_href);
  my $ann_snp_attr_href = $ann_snp_obj->header_attr;

  my %obj_attrs = map { $_ => 1 }
    ( keys %$ann_snp_attr_href, keys %$ann_attr_href, keys %$snp_attr_href );

  # some features are always expected
  @features =
    qw/ chr pos var_type alleles allele_count genomic_type site_type annotation_type ref_base
    minor_allele nearest_gene /;
  my %exp_features = map { $_ => 1 } @features;

  # add expected features from about to the features array to ensure we always have
  # certain features in our output
  for my $feature ( sort keys %obj_attrs ) {
    if ( !exists $exp_features{$feature} ) {
      push @features, $feature;
    }
  }

  # add genome score track names to @features
  for my $gs ( $self->_all_genome_scores ) {
    push @features, $gs->name;
  }
  push @features, 'cadd' if $self->has_cadd_track;

  # determine alt features and add them to @features
  my ( @alt_features, %gene_features, %snp_features );

  for my $gene_track ( $self->all_gene_tracks ) {
    my @gene_features = $gene_track->all_features;
    map { $gene_features{"alt_names.$_"}++ } @gene_features;
  }
  push @alt_features, $_ for sort keys %gene_features;

  for my $snp_track ( $self->all_snp_tracks ) {
    my @snp_features = $snp_track->all_features;

    # this is a hack to allow me to calcuate a single MAF for the snp
    # that's not already a value we retrieve and, therefore, doesn't fit in the
    # framework well
    push @snp_features, 'maf';
    map { $snp_features{"snp_feature.$_"}++ } @snp_features;
  }
  push @alt_features, $_ for sort keys %snp_features;

  # add alt features
  push @features, @alt_features;

  return \@features;
}

__PACKAGE__->meta->make_immutable;

1;
