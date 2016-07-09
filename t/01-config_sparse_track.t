#!perl -T
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

plan tests => 50;

my %attr_2_type = (
  type              => 'SparseTrackType',
  sql_statement     => 'Str',
  _local_files      => 'MouseX::Types::Path::Tiny::AbsPaths',
  features          => 'ArrayRef[Str]',
  gene_track_fields => 'ArrayRef',
  snp_track_fields  => 'ArrayRef',
);

my %attr_to_is = map { $_ => 'ro' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_config.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

my $package = "Seq::Config::SparseTrack";

# load package
use_ok($package) || die "$package cannot be loaded";

# check is moose object
check_isa( $package, [ 'Seq::Config::Track', 'Mouse::Object' ] );

# check roles
does_role( $package, 'MooX::Role::Logger' );

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

{
  # Generic object creation
  my $href = build_obj_data( 'sparse_tracks', 'snp', $config_href );
  my @features = qw/ alleleFreqCount alleles alleleFreqs /;
  $href->{features} = \@features;
  my $obj = $package->new($href);
  ok( $obj, 'object creation' );

  # snp sparse track
  my $st = $package->new(
    {
      name          => 'snp141',
      type          => 'snp',
      sql_statement => 'SELECT _snp_fields FROM hg38.snp141',
      features      => \@features,
      local_files   => ['snp141.txt.gz'],
      genome_chrs   => $config_href->{genome_chrs},
      # purposefully missing genome_raw_dir to test all_local_files
      #genome_raw_dir => $config_href->{genome_raw_dir},
    }
  );

  # local raw files
  my $exp_path =
    path( $config_href->{genome_raw_dir} )->child('./snp/hg38.snp141.txt')->absolute;
  is_deeply( $obj->all_local_files, $exp_path, 'local_files' );

  # raw local files using default genome_index_dir
  $exp_path = path(".")->child('raw/snp/snp141.txt.gz')->absolute;
  is_deeply( $st->all_local_files, $exp_path,
    'all_local_files with missing genome_raw_dir' );

  # local index files
  $exp_path =
    path( $config_href->{genome_index_dir} )->child('snp141.snp.chr1.kch')->absolute;
  is( $obj->get_kch_file('chr1'), $exp_path, 'method: get_kch_file (index file)' );
  $exp_path =
    path( $config_href->{genome_index_dir} )->child('snp141.snp.chr1.dat')->absolute;
  is( $obj->get_dat_file( 'chr1', $obj->type ),
    $exp_path, 'method: get_dat_file (index file)' );

  # as_href (to be used to create objects in other contexts beyond the configuration step)
  {
    # need to clean up the path (b/c of Path::Tiny), and add remote_files to the href to
    # make the data appear as as_href() ought to produce
    my $test_href = $href;
    $test_href->{genome_index_dir} =~ s/\A[\.\/]+//;
    $test_href->{genome_raw_dir} =~ s/\A[\.\/]+//;
    $test_href->{remote_files} = [];
    is_deeply( $obj->as_href, $test_href, 'method: as_href' );

    # re-make obj with data from as_href
    my $new_obj_data_href = $obj->as_href;
    my $new_obj           = $package->new($new_obj_data_href);
    ok( $new_obj, 'created obj using data from as_href' );

    # NOTE: since all_local_files is made when called (i.e., lazy) comparing the old and new object
    #       will fail without first calling all_local_files on the new object to populate that
    is_deeply( $obj->all_local_files, $new_obj->all_local_files,
      'new object makes all_local_files()' );
    is_deeply( $obj, $new_obj, 'new object == old obj' );
  }

  my @all_snp_fields = qw/ chrom chromStart chromEnd name /;
  push @all_snp_fields, @features;

  is_deeply( \@all_snp_fields, $st->snp_fields_aref,
    '(snp_track) method: Snp Fields Aref' );

  is( undef, $st->gene_fields_aref, '(snp_track) method: Gene Fields Aref' );

  my @got_features = $st->all_features;
  is_deeply( \@features, \@got_features, '(snp_track) method: features' );
}

{
  # check gene sparse track
  my @features =
    qw/ mRNA spID spDisplayID geneSymbol refseq protAcc description rfamAcc /;

  my $st = $package->new(
    {
      name => 'knownGene',
      type => 'gene',
      sql_statement =>
        'SELECT _gene_fields FROM hg38.knownGene LEFT JOIN hg38.kgXref ON hg38.kgXref.kgID = hg38.knownGene.name',
      features    => \@features,
      genome_chrs => $config_href->{genome_chrs},
    }
  );

  my @all_gene_fields =
    qw/ chrom strand txStart txEnd cdsStart cdsEnd exonCount exonStarts exonEnds name /;

  push @all_gene_fields, @features;

  is_deeply( \@all_gene_fields, $st->gene_fields_aref,
    '(gene_track) method: Gene Fields Aref' );

  is( undef, $st->snp_fields_aref, '(gene_track) method: Snp Fields Aref' );

  my @got_features = $st->all_features;

  is_deeply( \@features, \@got_features, '(gene_track) method: features' );
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
