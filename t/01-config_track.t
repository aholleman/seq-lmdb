#!perl -T
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

plan tests => 47;

my %attr_2_type = (
  name             => 'Str',
  genome_chrs      => 'ArrayRef[Str]',
  next_chr         => 'HashRef',
  genome_index_dir => 'MouseX::Types::Path::Tiny::Path',
  genome_raw_dir   => 'MouseX::Types::Path::Tiny::Path',
  local_files      => 'ArrayRef',
  remote_dir       => 'Str',
  remote_files     => 'ArrayRef',
);

my %attr_to_is = map { $_ => 'ro' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_config.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq::Config::Track";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extension of Seq::Config::Track
check_isa( $package, ['Mouse::Object'] );

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

my $href = build_obj_data( 'genome_sized_tracks', 'genome', $config_href );
my $obj = $package->new($href);

my @paths = qw/ genome_index_dir genome_raw_dir /;
for my $attr (@paths) {
  is( $obj->$attr, path( $config_href->{$attr} )->stringify, "attr: $attr" );
}

# Method tests
{
  my $exp_next_chrs_href = {
    chrM  => "chrX",
    chrX  => "chrY",
    chrY  => undef,
    chr1  => "chr2",
    chr2  => "chr3",
    chr3  => "chr4",
    chr4  => "chr5",
    chr5  => "chr6",
    chr6  => "chr7",
    chr7  => "chr8",
    chr8  => "chr9",
    chr9  => "chr10",
    chr10 => "chr11",
    chr11 => "chr12",
    chr12 => "chr13",
    chr13 => "chr14",
    chr14 => "chr15",
    chr15 => "chr16",
    chr16 => "chr17",
    chr17 => "chr18",
    chr18 => "chr19",
    chr19 => "chr20",
    chr20 => "chr21",
    chr21 => "chr22",
    chr22 => "chrM",
  };
  my %obs_result;
  for my $chr ( @{ $config_href->{genome_chrs} } ) {
    $obs_result{$chr} = $obj->get_next_chr($chr);
  }
  is_deeply( $exp_next_chrs_href, \%obs_result, 'method: get_next_chr' );
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
