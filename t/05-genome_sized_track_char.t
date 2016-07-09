#!perl -T
use 5.10.0;
use strict;
use warnings;

use Lingua::EN::Inflect qw/ A PL_N /;
use IO::Uncompress::Gunzip qw( $GunzipError );
use Path::Tiny;
use Test::More;
use Scalar::Util qw/ blessed /;
use YAML qw/ LoadFile /;

use DDP;
use Data::Dump qw/ dump /;

plan tests => 19;

# set test genome
my $ga_config   = path('./t/hg38_test.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# test the package's attributes and type constraints
my $package = "Seq::GenomeBin";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extends
check_isa( $package,
  [ 'Seq::Config::GenomeSizedTrack', 'Seq::Config::Track', 'Mouse::Object' ] );

# Attribute tests for class
my @ro_attrs = qw/ bin_seq chr_len /;
for my $attr (@ro_attrs) {
  has_ro_attr( $package, $attr );
}

# check type constraint: bin_seq => ScalarRef
for my $attr_name (qw( bin_seq )) {
  my $attr = $package->meta->get_attribute($attr_name);
  ok( $attr->has_type_constraint, "$package $attr_name has a type constraint" );
  is( $attr->type_constraint->name, 'ScalarRef', "$attr_name type is ScalarRef" );
}

# check type constraint: chr_len => HashRef[Str] values
for my $attr_name (qw( chr_len )) {
  my $attr = $package->meta->get_attribute($attr_name);
  ok( $attr->has_type_constraint, "$package $attr_name has a type constraint" );
  is( $attr->type_constraint->name, 'HashRef[Str]',
    "$attr_name type is HashRef[Str]" );
}

# object creation
{
  my $seq = '';
  my %chr_len;
  for my $chr ( @{ $config_href->{genome_chrs} } ) {
    my $bin_seq = pack( 'C', int( rand(4) ) ) x int( rand(10) + 1 );
    $seq .= $bin_seq;
    $chr_len{$chr} = length $bin_seq;
  }
  my $href = build_obj_data( 'genome_sized_tracks', 'genome', $config_href );
  $href->{bin_seq} = \$seq;
  $href->{chr_len} = \%chr_len;
  my $obj = $package->new($href);
  ok( $obj, 'object creation' );
}

# test charGenome stuff for 'score' type
{
  my $track_name = 'phyloP';
  my @test_scores;
  for ( my $i = -60; $i < 61; $i++ ) {
    push @test_scores, $i / 2;
  }
  my $bin_seq;
  my $score2char_phyloP = sub {
    my ($score) = @_;
    int( $score * ( 127 / 30 ) ) + 128;
  };
  my $char2score_phyloP = sub {
    my ($char) = @_;
    ( $char && $char > 0 )
      ? sprintf( "%0.3f", ( ( $_[0] - 128 ) / ( 127 / 30 ) ) )
      : undef;
  };

  # score creation / retrieval
  my ( @exp_scores, @obs_scores );
  for my $i (@test_scores) {
    my $char = $score2char_phyloP->($i);
    $bin_seq .= pack( 'C', $char );
    push @exp_scores, sprintf( "%0.3f", $char2score_phyloP->($char) );
  }
  my $char_genome_track = $package->new(
    {
      name        => $track_name,
      char2score  => $char2score_phyloP,
      score2char  => $score2char_phyloP,
      bin_seq     => \$bin_seq,
      chr_len     => {},
      genome_chrs => [],
      type        => 'score',
    }
  );
  isa_ok( $char_genome_track, $package,
    "$package obj created with phyloP constructors" );
  is( $char_genome_track->name, $track_name, "$package name set correctly" );

  for my $i ( 0 .. $#test_scores ) {
    push @obs_scores, $char_genome_track->get_score($i);
  }

  # check score retrieval
  is_deeply( \@obs_scores, \@exp_scores, 'get scores' );
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
