#!perl -T
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

plan tests => 65;

my %attr_2_type_ro = (
  snpfile            => 'MouseX::Types::Path::Tiny::AbsFile',
  config_file        => 'MouseX::Types::Path::Tiny::AbsFile',
  out_file           => 'MouseX::Types::Path::Tiny::AbsPath',
  ignore_unknown_chr => 'Bool',
  overwrite          => 'Bool',
  debug              => 'Int',
  write_batch        => 'Int',
);
my %attr_2_type_rw = (
  counter         => 'Num',
  del_sites       => 'HashRef',
  ins_sites       => 'HashRef',
  snp_sites       => 'HashRef',
  genes_annotated => 'HashRef',
);
my %attr_to_is_ro = map { $_ => 'ro' } ( keys %attr_2_type_ro );
my %attr_to_is_rw = map { $_ => 'rw' } ( keys %attr_2_type_rw );
my %attr_to_is = ( %attr_to_is_ro, %attr_to_is_rw );

# set test genome
my $ga_config   = path('./t/hg38_test.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extension of
check_isa( $package, ['Mouse::Object'] );

# check roles
does_role( $package, 'MooX::Role::Logger' );

# check attributes, their type constraint, and 'ro'/'rw' status
for my $attr_name ( sort ( keys %attr_2_type_ro, keys %attr_2_type_rw ) ) {
  my $exp_type = $attr_2_type_ro{$attr_name} || $attr_2_type_rw{$attr_name};
  my $attr = $package->meta->get_attribute($attr_name);
  next unless $exp_type;
  ok( $attr->has_type_constraint, "$package $attr_name has a type constraint %s" );
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

# object creation
{
  # make fake snpfile
  open my $fh, '>', 'test.snp' || die "cannot open 'test.snp': $!\n";
  close $fh;
  my $obj = $package->new(
    {
      config_file => $ga_config,
      file_type   => 'snp_2',
      snpfile     => 't/snp_test.snp'
    }
  );
  ok( $obj, 'object creation' );

  # clean up
  unlink 'test.snp' || die "cannot rm 'test.snp': $!\n";
}

# Methods tests

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
