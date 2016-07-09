#!perl -T
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

plan tests => 26;

# check attributes and type constraints
my %attr_2_type = (
  genome_str_track      => 'Seq::Build::GenomeSizedTrackStr',
  counter               => 'Num',
  bulk_insert_threshold => 'Num',
  force                 => 'Bool',
);
my %attr_to_is = map { $_ => 'ro' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_test.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq::Build::SparseTrack";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extends
check_isa( $package,
  [ 'Seq::Config::SparseTrack', 'Seq::Config::Track', 'Mouse::Object' ] );

# check roles
for my $role (qw/ MooX::Role::Logger /) {
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

exit;
# TODO: these tests are old and need updating
#       - create object
#       - emit data for storage
#       - _has_site_range_file() needs a test
#       - _get_range_list() needs a test

{
  my $dbsnp = Seq::Build::SparseTrack->new();
  ok( ( $dbsnp && ( blessed $dbsnp || !ref $dbsnp ) && $dbsnp->isa($package) ),
    "$package obj created" );

  my @exp_history = ();
  my $data        = [
    {
      abs_pos  => 100,
      features => {
        thing1 => 'good',
        thing2 => 'sublime',
      },
    },
    {
      abs_pos  => 200,
      features => { talks => 'sometimes', },
    },
    {
      abs_pos  => 300,
      features => { good_driver => 'very', },
    },
  ];

  for my $entry (@$data) {
    is(
      '',
      $dbsnp->have_annotated_site( $entry->{abs_pos} ),
      'history correctly does not find abs_pos'
    );
    $dbsnp->abs_pos( $entry->{abs_pos} );
    $dbsnp->features( $entry->{features} );
    is_deeply( $dbsnp->save_site_and_Serialize, $entry, 'Serialized entry' );
    $dbsnp->clear_all;
    is( $dbsnp->has_abs_pos, '',    'cleared attrib abs_pos' );
    is( $dbsnp->abs_pos,     undef, 'cleared abs_pos' );
    is(
      1,
      $dbsnp->have_annotated_site( $entry->{abs_pos} ),
      'history correcly finds abs_pos'
    );
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
