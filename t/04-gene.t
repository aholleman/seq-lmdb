#!perl -T
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

use Seq::KCManager;
use Seq::Site::Annotation;
use Seq::Site::Snp;

#plan tests => 1740;

# check attributes and their type constraints
my %attr_2_type = (
  chr                     => 'Str',
  strand                  => 'Str',
  transcript_id           => 'Str',
  transcript_start        => 'Int',
  transcript_end          => 'Int',
  coding_start            => 'Int',
  coding_end              => 'Int',
  exon_starts             => 'ArrayRef[Int]',
  exon_ends               => 'ArrayRef[Int]',
  alt_names               => 'HashRef',
  transcript_seq          => 'Str',
  transcript_annotation   => 'Str',
  transcript_abs_position => 'ArrayRef',
  transcript_error        => 'ArrayRef',
  peptide                 => 'Str',
  transcript_sites        => 'ArrayRef[Seq::Site::Gene]',
  flanking_sites          => 'ArrayRef[Seq::Site::Gene]',
);

my %attr_to_is = map { $_ => 'rw' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_test.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq::Gene";

# load package
use_ok($package) || die "$package cannot be loaded";

# check package extends Seq::Gene which is a Mouse::Object
check_isa( $package, ['Mouse::Object'] );

# check attributes, their type constraint, and 'ro'/'rw' status
for my $attr_name ( sort keys %attr_2_type ) {
  my $exp_type = $attr_2_type{$attr_name};
  my $attr     = $package->meta->get_attribute($attr_name);
  ok( $attr->has_type_constraint, "$package $attr_name has a type constraint" );
  is( $attr->type_constraint->name, $exp_type, "$attr_name type is $exp_type" );

  # check 'ro' / 'rw' status
  if ( $attr_to_is{$attr_name} eq 'ro' ) {
    has_ro_attr( $package, $attr_name );
  }
  elsif ( $attr_to_is{$attr_name} eq 'rw' ) {
    has_rw_attr( $package, $attr_name );
  }
  else {
    printf( "ERROR - expect 'ro' or 'rw' but got '%s'", $attr_to_is{$attr_name} );
    exit(1);
  }
}

SKIP: {

  # we need the gene and snp kch files and the dbsnp file to verify we make the sample
  # predictions that dbsnp makes on variants.
  my $chr22_offset = 2824183054;                                # for hg38
  my $snp_dbm      = path('big_files/snp141.snp.chr22.kch');
  my $gene_dbm     = path('big_files/knownGene.gene.chr22.kch');
  my $dbsnp_file   = path('big_files/snp141.chr22.txt');

  # check files are available
  skip "need big_files but didn't find them", 1,
    unless ( $snp_dbm->is_file && $gene_dbm->is_file && $dbsnp_file->is_file );

  # exp test types
  my $exp_site_tests = {
    "coding-synon"   => { "+" => 101, "-" => 49 },
    "intron"         => { "+" => 101, "-" => 101 },
    "missense"       => { "+" => 101, "-" => 97 },
    "ncRNA"          => { "+" => 101, "-" => 43 },
    "near-gene-3"    => { "+" => 101, "-" => 69 },
    "near-gene-5"    => { "+" => 101, "-" => 101 },
    "nonsense"       => { "+" => 83,  "-" => 7 },
    "splice-3"       => { "+" => 34,  "-" => 1 },
    "splice-5"       => { "+" => 44,  "-" => 3 },
    "stop-loss"      => { "+" => 2 },
    "untranslated-3" => { "+" => 101, "-" => 101 },
    "untranslated-5" => { "+" => 101, "-" => 9 },
  };

  # create the database object
  my $obs_snp_obj = Seq::KCManager->new(
    { filename => $snp_dbm->absolute->stringify, mode => 'read', } );
  my $obs_gene_obj = Seq::KCManager->new(
    { filename => $gene_dbm->absolute->stringify, mode => 'read', } );
  my %comp_base_lu = ( 'A' => 'T', 'C' => 'G', 'G' => 'C', 'T' => 'A' );

  my $non_coding_snp_href = {
    "intron" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{snp_id},    'intron' ];
      my $exp_aref = [ $exp_href->{name}, $exp_href->{func} ];
      my $msg      = sprintf( "snp: %s, strand: %s, miso: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func}, );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "near-gene-3" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{snp_id},    'near-gene-3' ];
      my $exp_aref = [ $exp_href->{name}, $exp_href->{func} ];
      my $msg      = sprintf( "snp: %s, strand: %s, miso: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func}, );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "near-gene-5" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{snp_id},    'near-gene-5' ];
      my $exp_aref = [ $exp_href->{name}, $exp_href->{func} ];
      my $msg      = sprintf( "snp: %s, strand: %s, miso: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func}, );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
  };
  my $gene_snp_href = {
    "untranslated-5" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, ];
      my $exp_aref = [ 'Non-Coding', '5UTR', ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "stop-loss" => sub {
      my ( $ann, $exp_href ) = @_;
      my $new_AA;
      if ( $ann->{new_aa_residue} ne '*' or $ann->{new_aa_residue} ne 'NA' ) {
        $new_AA = "OK";
      }
      my $obs_aref =
        [ $ann->{annotation_type}, $ann->{site_type}, $ann->{ref_aa_residue}, $new_AA ];
      my $exp_aref = [ 'Replacement', 'Coding', '*', 'OK' ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "frameshift" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, ];
      my $exp_aref = [ 'Replacement', 'Coding', ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "untranslated-3" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, ];
      my $exp_aref = [ 'Non-Coding', '3UTR', ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "splice-3" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, ];
      my $exp_aref = [ 'Non-Coding', 'Splice Acceptor', ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "nonsense" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref =
        [ $ann->{annotation_type}, $ann->{site_type}, $ann->{new_aa_residue}, ];
      my $exp_aref = [ 'Replacement', 'Coding', '*', ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "splice-5" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, ];
      my $exp_aref = [ 'Non-Coding', 'Splice Donor', ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "missense" => sub {
      my ( $ann, $exp_href ) = @_;
      my $aa_change;
      if ( $ann->{ref_aa_residue} ne $ann->{new_aa_residue} ) {
        $aa_change = 'OK';
      }
      else {
        $aa_change = sprintf(
          "ref aa, '%s', should differ from obs aa, '%s'",
          $ann->{new_aa_residue},
          $ann->{new_aa_residue}
        );
      }
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, $aa_change ];
      my $exp_aref = [ 'Replacement', 'Coding', 'OK' ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "coding-synon" => sub {
      my ( $ann, $exp_href ) = @_;
      my $aa_change;
      if ( $ann->{ref_aa_residue} eq $ann->{new_aa_residue} ) {
        $aa_change = 'OK';
      }
      else {
        $aa_change = sprintf(
          "found aa: %s, expected: %s",
          $ann->{new_aa_residue},
          $ann->{ref_aa_residue}
        );
      }
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, $aa_change ];
      my $exp_aref = [ 'Silent', 'Coding', 'OK' ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
    "ncRNA" => sub {
      my ( $ann, $exp_href ) = @_;
      my $obs_aref = [ $ann->{annotation_type}, $ann->{site_type}, ];
      my $exp_aref = [ 'Non-Coding', 'non-coding RNA', ];
      my $msg = sprintf(
        "snp: %s, strand: %s, miso: %s, site_type: %s, annotation_type: %s",
        $exp_href->{name}, $exp_href->{strand}, $exp_href->{func},
        $ann->{site_type}, $ann->{annotation_type},
      );
      is_deeply( $obs_aref, $exp_aref, $msg );
    },
  };
  my %snp_types = ( %$non_coding_snp_href, %$gene_snp_href );

  # read in data
  my %func       = ();
  my $dbsnp_txt  = $dbsnp_file->slurp;
  my @dbsnp_data = split /\n/, $dbsnp_txt;
  my %dbsnp_header;
  for my $line (@dbsnp_data) {
    my @fields = split /\t/, $line;
    if ( !%dbsnp_header ) {
      %dbsnp_header = map { $fields[$_] => $_ } ( 0 .. $#fields );
    }
    else {
      my %data = map { $_ => $fields[ $dbsnp_header{$_} ] } ( keys %dbsnp_header );

      # site must have a UCSC reference base: A, C, G, or T
      next unless exists $comp_base_lu{ $data{refUCSC} };

      # site must have minor allele
      next unless exists $data{observed};

      # site must have only 1 predicted function
      next unless exists $snp_types{ $data{func} };

      # get expected snp functions
      my %exp_func = map { $_ => 1 } ( split /\,/, $data{func} );

      my @alleles = split /\//, $data{observed};
      my @non_ref_alleles;

      if ( $data{strand} eq '+' ) {
        for my $allele (@alleles) {
          next unless exists $comp_base_lu{$allele};
          next if $data{refUCSC} eq $allele;
          # save the + allele
          push @non_ref_alleles, $allele;
        }
      }
      else {
        for my $allele (@alleles) {
          next unless exists $comp_base_lu{$allele};
          next if $comp_base_lu{ $data{refUCSC} } eq $allele;
          # rev_comp the - allele to +
          push @non_ref_alleles, $comp_base_lu{$allele};
        }
      }

      # get rid of multi-alleleic sites
      next unless scalar @non_ref_alleles == 1;

      # skip indel sites
      next unless exists $comp_base_lu{ $non_ref_alleles[0] };

      # we are not interested in testing _all_ sites just some # of them
      if ( exists $func{ $data{func} }{ $data{strand} } ) {
        next if $func{ $data{func} }{ $data{strand} } > 100;
      }

      # get snp data
      my $abs_pos      = $data{chromStart} + $chr22_offset;
      my $obs_snp_aref = $obs_snp_obj->db_get($abs_pos);

      # get gene data
      my $obs_gene_aref = $obs_gene_obj->db_get($abs_pos);

      if ( defined $obs_gene_aref ) {

        # since we're in the gene only look at sites that cause changes w/in a gene
        next unless exists $gene_snp_href->{ $data{func} };

        # let's just look at places where there's only 1 gene
        next if scalar @$obs_gene_aref != 1;

        # say "data: " . dump( \%data);
        # say "non-ref allele: " . dump( \@non_ref_alleles );

        # cycle through all of the entries for the gene
        for my $entry (@$obs_gene_aref) {
          for my $minor_allele (@non_ref_alleles) {
            $entry->{minor_allele} = $minor_allele;
            my $ann = Seq::Site::Annotation->new($entry)->as_href_with_NAs;
            if ( $gene_snp_href->{ $data{func} }->( $ann, \%data ) ) {
              $func{ $data{func} }{ $data{strand} }++;
            }
          }
        }
      }
      else {
        next unless exists $non_coding_snp_href->{ $data{func} };
        for my $entry (@$obs_snp_aref) {
          my $ann = Seq::Site::Snp->new($entry)->as_href_with_NAs;
          if ( $non_coding_snp_href->{ $data{func} }->( $ann, \%data ) ) {
            $func{ $data{func} }{ $data{strand} }++;
          }
        }
      }

    }
  }
  is_deeply( $exp_site_tests, \%func, 'Sites Tested' );
  say dump( \%func );
}
done_testing();

###############################################################################
# sub routines
###############################################################################

sub build_obj_data {
  my ( $track_type, $type, $href ) = @_;

  my %hash;

  # get essential stuff
  for my $track ( @{ $config_href->{$track_type} } ) {
    if ( $track->{type} eq $type ) {
      for my $attr (qw/ name type local_files remote_dir remote_files /) {
        $hash{$attr} = $track->{$attr} if exists $track->{$attr};
      }
    }
  }

  # add additional stuff
  if (%hash) {
    $hash{genome_raw_dir}   = $config_href->{genome_raw_dir}   || 'sandbox';
    $hash{genome_index_dir} = $config_href->{genome_index_dir} || 'sandbox';
    $hash{genome_chrs}      = $config_href->{genome_chrs};
  }
  return \%hash;
}

sub does_role {
  my $package = shift;
  my $role    = shift;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  ok( $package->meta->does_role($role), "$package does the $role role" );
}

sub check_isa {
  my $class   = shift;
  my $parents = shift;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my @isa = $class->meta->linearized_isa;
  shift @isa; # returns $class as the first entry

  my $count = scalar @{$parents};
  my $noun = PL_N( 'parent', $count );

  is( scalar @isa, $count, "$class has $count $noun" );

  for ( my $i = 0; $i < @{$parents}; $i++ ) {
    is( $isa[$i], $parents->[$i], "parent[$i] is $parents->[$i]" );
  }
}

sub has_ro_attr {
  my $class = shift;
  my $name  = shift;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $articled = A($name);
  ok( $class->meta->has_attribute($name), "$class has $articled attribute" );

  my $attr = $class->meta->get_attribute($name);

  is( $attr->get_read_method, $name,
    "$name attribute has a reader accessor - $name()" );
  is( $attr->get_write_method, undef, "$name attribute does not have a writer" );
}

sub has_rw_attr {
  my $class      = shift;
  my $name       = shift;
  my $overridden = shift;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $articled = $overridden ? "an overridden $name" : A($name);
  ok( $class->meta->has_attribute($name), "$class has $articled attribute" );

  my $attr = $class->meta->get_attribute($name);

  is( $attr->get_read_method, $name,
    "$name attribute has a reader accessor - $name()" );
  is( $attr->get_write_method, $name,
    "$name attribute has a writer accessor - $name()" );
}
