#!perl
use 5.10.0;
use strict;
use warnings;

use Data::Dump qw/ dump /;
use Lingua::EN::Inflect qw/ A PL_N /;
use Log::Any::Adapter;
use Path::Tiny;
use Test::More;
use YAML qw/ LoadFile /;

plan tests => 10;

my %attr_2_type = ();
my %attr_to_is = map { $_ => 'ro' } ( keys %attr_2_type );

# set test genome
my $ga_config   = path('./t/hg38_test.yml')->absolute->stringify;
my $config_href = LoadFile($ga_config);

# set package name
my $package = "Seq::Fetch";

# load package
use_ok($package) || die "$package cannot be loaded";

# check extension of
check_isa( $package, [ 'Seq::Assembly', 'Mouse::Object' ] );

# check roles
for my $role (qw/ MooX::Role::Logger Seq::Role::ConfigFromFile /) {
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

my $log_name = join '.', 'fetch', $config_href->{genome_name}, 'log';
my $log_file = path("./t")->child($log_name)->absolute->stringify;
Log::Any::Adapter->set( 'File', $log_file );

# fetch snp track data
{
  # set verbose output but don't actually get data
  $config_href->{debug} = 1;
  $config_href->{act}   = 0;
  my $obj = $package->new($config_href);
  ok( $obj,                 'object creation' );
  ok( $obj->fetch_snp_data, 'fetch_snp_data()' );
}

# fetch gene track data
{
  # set verbose output but don't actually get data
  $config_href->{debug} = 1;
  $config_href->{act}   = 0;
  my $obj = $package->new($config_href);
  ok( $obj,                  'object creation' );
  ok( $obj->fetch_gene_data, 'fetch_gene_data()' );
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
      for my $attr (qw/ name type local_files remote_dir remote_files features /) {
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

__END__
#
# test the package with the test data
#

# set test yaml config file
my $config_file = "test_annotation.yml";

# load the config file
my $config_href = LoadFile($config_file)
  || die "cannot load $config_file: $!\n";

# choose a genome entry to test
my $genome = "hg38";
my $hg38_config_href //= $config_href->{$genome}
  || die "cannot find $genome in $config_file\n";

# load configuration package
use_ok('Seq::Config') || die "cannot load Seq::Config\n";

# make configuration obj
my $hg38_config_obj = Seq::Config->new($hg38_config_href);

# test normal connection and methods
{
  # setup mock DBI driver
  my $drh       = DBI->install_driver('Mock');
  my $init_hg38 = Seq::Build::Fetch->new(
    {
      dsn    => 'dbi:Mock',
      config => $hg38_config_obj,
    }
  );

  # check dbh method returns DBI::db obj
  can_ok( $init_hg38, 'dbh' );
  isa_ok( $init_hg38->dbh(), 'DBI::db' );

  # test config handles
  is( $init_hg38->genome_name,     "hg38",      "handles genome_name() works." );
  is( $init_hg38->gene_track_name, "knownGene", "handles gene_track_name() works." );
  is( $init_hg38->snp_track_name,  "snp141",    "handles snp_track_name() works." );
  my $exp_statement =
    qq{SELECT * FROM hg38.knownGene LEFT JOIN hg38.kgXref ON hg38.kgXref.kgID = hg38.knownGene.name};
  is( $init_hg38->gene_track_statement,
    $exp_statement, "handles gene_track_statement() works." );
  $exp_statement =
    q{SELECT $fields FROM hg38.snp141 where hg38.snp141.chrom = "chr22"};
  like( $init_hg38->snp_track_statement,
    qr/snp141/, "handles snp_track_statement() works." );

  # test good connection succeedes
  lives_ok { $init_hg38->dbh } 'dbh() succeeds if connection works.';
  lives_ok { $init_hg38->get_sql_aref('snp') }
  'get_sql_aref() succeeds if connection works.';
}

# test failure to connect throws error
{
  my $drh = DBI->install_driver('Mock');
  $drh->{mock_connect_fail} = 1;
  my $init_hg38 = Seq::Build::Fetch->new(
    {
      dsn    => 'dbi:Mock',
      config => $hg38_config_obj,
    }
  );
  throws_ok { $init_hg38->dbh } qr/Could not connect/,
    'dbh() fails if Db connection fails.';
  throws_ok { $init_hg38->get_sql_aref('snp') } qr/Could not connect/,
    'get_sql_aref() fails if Db connection fails.';
}

# test loss of Db connection throws error
TODO: {
  local $TODO = 'do not understand why these continue to fail (i.e., succeed)';
  my $drh = DBI->install_driver('Mock');
  $drh->{mock_connect_fail} = 0;
  my $init_hg38 =
    Seq::Build::Fetch->new( { dsn => 'dbi:Mock', config => $hg38_config_obj, } );
  my $sth = eval { $init_hg38->dbh()->prepare('Select foo FROM bar') };
  $init_hg38->dbh()->{mock_can_connect} = 0;
  throws_ok { $sth->execute(); } qr/Could not connect/, 'basic dbh error thrown';
  throws_ok { $init_hg38->get_sql_aref('snp') } qr/Could not connect/,
    'get_sql_aref() fails if Db connection fails';
}

# setup data for reading sql db tests
#   reads data after __END__
{
  my $dbh = DBI->connect('dbi:SQLite:dbname=test:hg38');
  local $/ = ";\n";
  $dbh->do($_) while <DATA>;
}

# fetch sql data
{
  my $drh = DBI->install_driver('SQLite');
  # make a local copy of the configuration hashref
  # change SQL statement to something simple to test
  my $local_hg38_config_href = $hg38_config_href;
  $local_hg38_config_href->{snp_track_statement} =
    'SELECT id, name, feature FROM test';
  my $local_hg38_config_obj = Seq::Config->new($local_hg38_config_href);
  my $init_hg38             = Seq::Build::Fetch->new(
    {
      dsn    => 'dbi:SQLite:dbname=test',
      host   => '',
      user   => '',
      config => $local_hg38_config_obj,
    }
  );
  my $exp_data = [ [ 1, 'GRN', 55 ], [ 2, 'Titan', 222, ], ];
  my $obs_data = $init_hg38->get_sql_aref('snp');
  is_deeply( $obs_data, $exp_data, 'fetched sql data' );
}

# write fetched sql data
{
  my $drh                    = DBI->install_driver('SQLite');
  my $local_hg38_config_href = $hg38_config_href;
  $local_hg38_config_href->{snp_track_statement} =
    'SELECT id, name, feature FROM test';
  my $local_hg38_config_obj = Seq::Config->new($local_hg38_config_href);
  my $init_hg38             = Seq::Build::Fetch->new(
    {
      dsn    => 'dbi:SQLite:dbname=test',
      host   => '',
      user   => '',
      config => $local_hg38_config_obj,
    }
  );
  my $exp_data = [ [ 1, 'GRN', 55 ], [ 2, 'Titan', 222, ], ];
  open my $out_fh, ">", "test.txt";
  $init_hg38->write_sql_data( 'snp', $out_fh );
  close $out_fh;
  my @obs_data;
  open my $in_fh, "<", "test.txt";

  while (<$in_fh>) {
    chomp $_;
    my @data = split( "\t", $_ );
    push @obs_data, \@data;
  }
  is_deeply( \@obs_data, $exp_data, 'wrote sql data' );
}

# check we say scripts to download data
for my $type (qw(seq phastCons phyloP)) {
  # setup expected data
  my $dir        = $hg38_config_href->{"$type\_dir"};
  my $file_aref  = $hg38_config_href->{"$type\_files"};
  my $command    = "rsync -naz rsync://$dir";
  my $exp_script = join( "\n", "#!/bin/bash", map { "$command/$_ ." } @$file_aref );
  my $local_hg38_config_obj = Seq::Config->new($hg38_config_href);
  my $init_hg38  = Seq::Build::Fetch->new( { config => $local_hg38_config_obj, } );
  my $obs_script = $init_hg38->say_fetch_files_script($type);
  is( $obs_script, $exp_script, "write script for $type data" );
}

# check we say scripts correctly for processing downloaded data
for my $type (qw(seq phastCons phyloP)) {
  # choose dm6 b/c it needs scripts to process genome
  my $dm6_config_href //= $config_href->{dm6};

  # move the following to the init script itself (i.e., not the method)
  my $cwd               = cwd();
  my $create_cons_prog  = "python $cwd/create_cons.py";
  my $split_wigFix_prog = "python $cwd/split_wigFix.py";
  my $extract_prog      = "python $cwd/extract.py";
  #$exp_script =~ s/create_cons\.py/$create_cons_prog/g;
  #$exp_script =~ s/extract\.py/$extract_prog/g;
  #$exp_script =~ s/split_wigFix\.py/$split_wigFix_prog/g
  #sub time_stamp {
  #return sprintf("%d-%02d-%02d", eval(localtime->year() + 1900),
  #  eval(localtime->mon() + 1), localtime->mday());
  #};

  # setup expected data
  my @cmds;
  foreach my $step (qw(proc_init proc_chr proc_dir_clean)) {
    my $key = "$type\_$step";
    next unless exists $dm6_config_href->{$key};
    if ( $step eq "proc_chr" ) {
      foreach my $chr ( @{ $dm6_config_href->{chr_names} } ) {
        my $this_cmd = join( "\n", @{ $dm6_config_href->{$key} } );
        $this_cmd =~ s/\$dir/$type/g;
        $this_cmd =~ s/\$chr/$chr/g;
        push @cmds, $this_cmd;
      }
    }
    else {
      my $this_cmd = join( "\n", @{ $dm6_config_href->{$key} } );
      push @cmds, $this_cmd;
    }
  }
  my $exp_script = (@cmds) ? join( "\n", "#!/bin/bash", @cmds ) : undef;
  my $local_dm6_config_obj = Seq::Config->new($dm6_config_href);
  my $init_dm6   = Seq::Build::Fetch->new( { config => $local_dm6_config_obj, } );
  my $obs_script = $init_dm6->say_process_files_script($type);
  is( $obs_script, $exp_script, "say $type processing script" );
}

# check rsync options are set correctly
{
  my %rsync_opts;
  $rsync_opts{1}{1} = "-avzP";
  $rsync_opts{1}{0} = "-az";
  $rsync_opts{0}{1} = "-navzP";
  $rsync_opts{0}{0} = "-naz";
  my $local_hg38_config_obj = Seq::Config->new($hg38_config_href);
  my ( @obs_rsync, @exp_rsync );
  foreach my $act ( sort keys %rsync_opts ) {

    foreach my $verbose ( sort keys %{ $rsync_opts{$act} } ) {
      my $init_hg38 = Seq::Build::Fetch->new(
        {
          act     => $act,
          verbose => $verbose,
          config  => $local_hg38_config_obj,
        }
      );
      push @obs_rsync, $init_hg38->_get_rsync_opts();
      push @exp_rsync, $rsync_opts{$act}{$verbose};
    }
  }
  is_deeply( \@obs_rsync, \@exp_rsync,, 'ok _get_rsync_opts' );
}

__END__
BEGIN TRANSACTION;
DROP TABLE test;
CREATE TABLE test (
  id int,
  name varchar(25),
  feature int
);
INSERT INTO "test" VALUES(1, 'GRN', 55);
INSERT INTO "test" VALUES(2, 'Titan', 222);
COMMIT;

# setup data for reading sql db tests
#   reads data after __END__
{
  my $dbh = DBI->connect('dbi:SQLite:dbname=test_hg38');
  local $/ = ";\n";
  $dbh->do($_) while <DATA>;
}

# load the yaml file
my $hg38_config_href = LoadFile($config_file)
  || die "cannot load $config_file $!\n";

for my $track ( @{ $hg38_config_href->{sparse_tracks} } ) {
  $track->{dsn}           = 'dbi:SQLite:dbname=test_hg38';
  $track->{host}          = '';
  $track->{user}          = '';
  $track->{sql_statement} = 'SELECT id, name, feature FROM test';
}

for my $track ( @{ $hg38_config_href->{genome_sized_tracks} } ) {
  $track->{act}     = 0;
  $track->{verbose} = 1;
}

my $fetch_hg38 = Seq::Fetch->new($hg38_config_href);

isa_ok( $fetch_hg38, 'Seq::Fetch', 'Seq::Fetch made with a hash reference' );

my $fetch_hg38_2 = Seq::Fetch->new_with_config(
  { configfile => $config_file, act => 1, verbose => 1, } );

isa_ok( $fetch_hg38_2, 'Seq::Fetch', 'Seq::Fetch made with a configfile' );

$fetch_hg38_2->fetch_genome_size_tracks;

__DATA__
BEGIN TRANSACTION;
DROP TABLE test;
CREATE TABLE test (
  id int,
  name varchar(25),
  feature int
);
INSERT INTO "test" VALUES(1, 'GRN', 55);
INSERT INTO "test" VALUES(2, 'Titan', 222);
COMMIT;
