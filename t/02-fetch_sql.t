#!perl -T
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

plan tests => 51;

my %attr_2_type = (
  act      => 'Bool',
  debug    => 'Int',
  dsn      => 'Str',
  host     => 'Str',
  user     => 'Str',
  password => 'Str',
  port     => 'Int',
  socket   => 'Str',
);
my %attr_to_is = map { $_ => 'ro' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_test.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq::Fetch::Sql";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extension of
check_isa( $package,
  [ 'Seq::Config::SparseTrack', 'Seq::Config::Track', 'Mouse::Object' ] );

# check roles
for my $role (qw/ MooX::Role::Logger Seq::Role::IO /) {
  does_role( $package, $role );
}

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

# snp - object creation
{
  my $href = build_obj_data( 'sparse_tracks', 'snp', $config_href );
  $href->{db} = $config_href->{genome_name};
  my $obj = $package->new($href);
  ok( $obj, 'snp track object creation' );
  (
    my $snp_sql_stmt =
      q{SELECT chrom, chromStart, chromEnd, name, alleles,
  alleleFreqs, alleleFreqCount, func, refUCSC, strand FROM hg38.snp141 where
  hg38.snp141.chrom = 'chr22'}
  ) =~ s/[\n\s]+/ /xmgs;
  is( $obj->sql_statement, $snp_sql_stmt, 'sql statement for snp' );
}

# gene - object creation
{
  my $href = build_obj_data( 'sparse_tracks', 'gene', $config_href );
  $href->{db} = $config_href->{genome_name};
  my $obj = $package->new($href);
  ok( $obj, 'gene track object creation' );
  (
    my $gene_sql_stmt =
      q{SELECT chrom, strand, txStart, txEnd, cdsStart, cdsEnd,
  exonCount, exonStarts, exonEnds, name, mRNA, spID, spDisplayID, geneSymbol,
  refseq, protAcc, description, rfamAcc FROM hg38.knownGene LEFT JOIN hg38.kgXref
  ON hg38.kgXref.kgID = hg38.knownGene.name where hg38.knownGene.chrom = 'chr22'}
  ) =~ s/[\n\s]+/ /xmgs;
  is( $obj->sql_statement, $gene_sql_stmt, 'sql statement for gene' );
}

###############################################################################
# sub routines
###############################################################################

sub build_obj_data {
  my ( $track_type, $type, $href ) = @_;

  my %hash;

  # get essential stuff
  for my $track ( @{ $config_href->{$track_type} } ) {
    if ( $track->{type} eq $type ) {
      for my $attr (
        qw/ name type local_files remote_dir remote_files features
        sql_statement act verbose dsn host user password port sokcet /
        )
      {
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
