#!perl -T
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

plan tests => 64;

my %attr_2_type = (
  type               => 'GenomeSizedTrackType',
  genome_str_file    => 'MouseX::Types::Path::Tiny::AbsPath',
  genome_bin_file    => 'MouseX::Types::Path::Tiny::AbsPath',
  genome_offset_file => 'MouseX::Types::Path::Tiny::AbsPath',
  _local_files       => 'MouseX::Types::Path::Tiny::AbsPaths',
  score_min          => 'Num',
  score_max          => 'Num',
  score_R            => 'Num',
  _score_beta        => 'Num',
  _score_lu          => 'HashRef'
);

my %attr_to_is = map { $_ => 'ro' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_config.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq::Config::GenomeSizedTrack";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extension of Seq::Config::Track
check_isa( $package, [ 'Seq::Config::Track', 'Mouse::Object' ] );

# check roles
does_role( $package, 'MooX::Role::Logger' );

# check attributes, their type constraint, and 'ro'/'rw' status
for my $attr_name ( sort keys %attr_2_type ) {
  my $exp_type = $attr_2_type{$attr_name};
  my $attr     = $package->meta->get_attribute($attr_name);
  ok( $attr->has_type_constraint, "$package $attr_name has a type constraint" );
  is( $attr->type_constraint->name, $exp_type, "$attr_name type is $exp_type" );

  # check ro/rw status
  if ( $attr_to_is{$attr_name} eq 'ro' ) {
    has_ro_attr( $package, $attr_name );
  }
  elsif ( $attr_to_is{$attr} eq 'rw' ) {
    has_rw_attr( $package, $attr_name );
  }
  else {
    printf( "ERROR - expect 'ro' or 'rw' but got '%s'", $attr_to_is{$attr_name} );
    exit(1);
  }
}

# object creation
my $href = build_obj_data( 'genome_sized_tracks', 'genome', $config_href );
my $obj = $package->new($href);
ok( $obj, 'object creation' );

{
  # as_href
  my $test_href = $href;
  $test_href->{genome_index_dir} =~ s/\A[\.\/]+//;
  $test_href->{genome_raw_dir} =~ s/\A[\.\/]+//;
  is_deeply( $test_href, $obj->as_href, 'method: as_href' );

  # re-make obj with data from as_href
  my $new_obj_data_href = $obj->as_href;
  my $new_obj           = $package->new($new_obj_data_href);
  ok( $new_obj, 'created obj using data from as_href' );
  is_deeply( $obj, $new_obj, 'new object == old obj' );
}

# Methods tests
#   1 - index coding:   get_idx_code
#   2 - index decoding: get_idx_base, get_idx_in_gan, get_idx_in_gene, get_idx_in_exon,
#                       get_idx_in_snp
{
  my ( %idx_codes, %idx_base, %idx_in_gan, %idx_in_gene, %idx_in_exon, %idx_in_snp );
  my %base_char_2_txt = ( '0' => 'N', '1' => 'A', '2' => 'C', '3' => 'G', '4' => 'T' );
  my @in_gan  = qw/ 0 8 /; # is gene annotated
  my @in_exon = qw/ 0 16 /;
  my @in_gene = qw/ 0 32 /;
  my @in_snp  = qw/ 0 64 /;

  # store vals for testing
  my ( %exp, %obs );
  foreach my $base_char ( keys %base_char_2_txt ) {
    foreach my $snp (@in_snp) {
      foreach my $gene (@in_gene) {
        foreach my $exon (@in_exon) {
          foreach my $gan (@in_gan) {
            my $char_code = $base_char + $gan + $gene + $exon + $snp;
            my $txt_base  = $base_char_2_txt{$base_char};

            # gather base codes
            push @{ $exp{base} }, $package->get_idx_base($char_code);
            push @{ $obs{base} }, $txt_base;

            # gather in gene annotation codes
            push @{ $exp{gan} }, $package->get_idx_in_gan($char_code);
            push @{ $obs{gan} }, ( $gan ? 1 : 0 );

            # gather in gene codes
            push @{ $exp{gene} }, $package->get_idx_in_gene($char_code);
            push @{ $obs{gene} }, ( $gene ? 1 : 0 );

            # gather in exon codes
            push @{ $exp{exon} }, $package->get_idx_in_exon($char_code);
            push @{ $obs{exon} }, ( $exon ? 1 : 0 );

            # gather in snp codes
            push @{ $exp{snp} }, $package->get_idx_in_snp($char_code);
            push @{ $obs{snp} }, ( $snp ? 1 : 0 );
          }
        }
      }
    }
  }

  # check build idx codes
  for my $type (qw/ base gan gene exon snp /) {
    is_deeply( $exp{$type}, $obs{$type}, "idx code for $type" );
  }
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
