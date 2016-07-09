#!perl -T
use 5.10.0;
use strict;
use warnings;

use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;
use Cpanel::JSON::XS;

use DDP;                   # for debugging
use Data::Dump qw/ dump /; # for debugging

plan tests => 39;

my %attr_2_type = (
  alleles      => 'Str',
  allele_count => 'Str',
  gene_data    => 'ArrayRef[Maybe[Seq::Site::Indel]]',
  het_ids      => 'Str',
  hom_ids      => 'Str',
  var_allele   => 'Str',
  var_type     => 'IndelType',
);
my %attr_to_is = map { $_ => 'ro' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_test.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq::Annotate::Indel";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extension of
check_isa( $package, [ 'Seq::Annotate::Site', 'Mouse::Object' ] );

# check role
#does_role( $package, 'Seq::Role::Serialize' );

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

# object creation
# for my $i ( 0 .. 6 ) {
#   my $obj_data_href = LoadJsonData("t/10-data.$i.json");
#   my $obj           = $package->new($obj_data_href);
#
#   # only test package creation once
#   if ( $i == 0 ) {
#     ok( $obj, $package );
#   }
#   my $obs_href = $obj->as_href;
#   #SaveJsonData( "10-exp.$i.json", $obs_href );
#
#   my $exp_href = LoadJsonData("t/10-exp.$i.json");
#   is_deeply( $obs_href, $exp_href, 'as_href()' );
# }

# Methods tests

###############################################################################
# sub routines
###############################################################################

sub SaveJsonData {
  my ( $file, $data ) = @_;
  my $fh = IO::File->new( $file, 'w' ) || die "$file: $!\n";
  print {$fh} encode_json($data);
  close $fh;
}

sub LoadJsonData {
  my $file = shift;
  my $fh = IO::File->new( $file, 'r' ) || die "$file: $!\n";
  local $\;
  my $json_txt = <$fh>;
  close $fh;
  my $jsonHref = decode_json($json_txt);
  if ( !%$jsonHref ) {
    say "Bail out - no data for $file";
    exit(1);
  }
  else {
    return $jsonHref;
  }
}

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
