use 5.10.0;
use strict;
use warnings;

package Utils::SqlWriter;

our $VERSION = '0.001';

# ABSTRACT: Fetch and write some data using UCSC's public SQL db
use Moose 2;

use DBI;
use namespace::autoclean;
use Time::localtime;
use Data::Dump qw/ dump /;
use Path::Tiny qw/path/;

with 'Seq::Role::IO', 'Seq::Role::Message';

# A valid SQL statement
has sql_statement => (is => 'ro', isa => 'Str', required => 1);

# hg19, hg38, etc
has assembly => (is => 'ro', isa => 'Str', required => 1);

# All of the chromosomes we want
has chromosomes => (is => 'ro', isa => 'ArrayRef', required => 1);

# Where any downloaded or created files should be saved
has outputDir => ( is => 'ro', isa => 'Str', required => 1);

# What is the "ID" of the files; we'll write chr.ID.txt
has name => ( is => 'ro', isa => 'Str', required => 1);

# Compress the output?
has compress => ( is => 'ro', isa => 'Bool', lazy => 1, default => 0);

############ DB Configuartion Vars #########################
my $year          = localtime->year() + 1900;
my $mos           = localtime->mon() + 1;
my $day           = localtime->mday;
my $nowTimestamp = sprintf( "%d-%02d-%02d", $year, $mos, $day );

has dsn  => ( is => 'ro', isa => 'Str',  required => 1, default => "DBI:mysql" );
has host => ( is => 'ro', isa => 'Str', lazy => 1, default  => "genome-mysql.cse.ucsc.edu");
has user => ( is => 'ro', isa => 'Str', required => 1, default => "genome" );
has password => ( is => 'ro', isa => 'Str', );
has port     => ( is => 'ro', isa => 'Int', );
has socket   => ( is => 'ro', isa => 'Str', );

=method @public sub dbh

  Build database object, and return a handle object

Called in: none

@params:

@return {DBI}
  A connection object

=cut

sub dbh {
  my $self = shift;
  my $dsn  = $self->dsn;
  $dsn .= ":" . $self->assembly;
  $dsn .= ";host=" . $self->host if $self->host;
  $dsn .= ";port=" . $self->port if $self->port;
  $dsn .= ";mysql_socket=" . $self->port_num if $self->socket;
  $dsn .= ";mysql_read_default_group=client";
  my %conn_attrs = ( RaiseError => 1, PrintError => 0, AutoCommit => 0 );
  return DBI->connect( $dsn, $self->user, $self->password, \%conn_attrs );
}

=method @public sub fetchAndWriteSQLData

  Read the SQL data and write to file


@return {DBI}
  A connection object

=cut
sub fetchAndWriteSQLData {
  my $self = shift;

  my $extension = $self->compress ? 'gz' : 'txt';

  # We'll return the relative path to the files we wrote
  my @outRelativePaths;
  for my $chr ( @{$self->chromosomes} ) {
    my $dbh = $self->dbh();

    # for return data
    my @sql_data = ();
    
    my $query = $self->sql_statement;

    my $name = join '.', $self->assembly, $self->name, $chr, $extension;
    my $timestampName = join '.', $nowTimestamp, $name;

    # Save the fetched data to a timestamped file, then symlink it to a non-timestamped one
    # This allows non-destructive fetching
    my $symlinkedFile = path($self->outputDir)->child($name)->absolute->stringify;
    my $targetFile = path($self->outputDir)->child($timestampName)->absolute->stringify;

    # prepare file handle
    my $outFh = $self->get_write_fh($targetFile);

    ########### Restrict SQL fetching to just this chromosome ##############

    # Get the FQ name (i.e hg19.refSeq.chrom instead of chrom), to avoid
    # Cases where in JOINS chrom exists in N tables
    $query =~ m/FROM\s(\S+)/i;
    my $fullyQualifiedTableName = $1;

    $query.= sprintf(" WHERE %s.chrom = '%s'", $1, $chr);

    $self->log('info', "Updated sql_statement to $query");

    ########### Prepare and execute SQL ##############
    my $sth = $self->dbh->prepare($query) or $self->log('fatal', $dbh->errstr);
    
    $sth->execute or $self->log('fatal', $dbh->errstr);

    ########### Retrieve data ##############
    my $count = 0;
    while ( my @row = $sth->fetchrow_array ) {
      if ( $count == 0 ) {
        push @sql_data, $sth->{NAME};
        $count++;
      } else {
        my $clean_row_aref = $self->_cleanRow( \@row );
        push @sql_data, $clean_row_aref;
      }

      if ( scalar @sql_data > 1000 ) {
        map { say {$outFh} join( "\t", @$_ ); } @sql_data;
        @sql_data = ();
      }

    }

    # leftovers
    if (@sql_data) {
      map { say {$outFh} join( "\t", @$_ ); } @sql_data;
      @sql_data = ();
    }

    $self->log("Finished writing $targetFile");

    # A track may not have any genes on a chr (e.g., refGene and chrM)
    if (-z $targetFile) {
      # Delete the symlink, it's empty
      unlink $targetFile;
      $self->log('info', "Skipping symlinking $targetFile, because it is empty");
      next;
    }

    if ( system("ln -s -f $targetFile $symlinkedFile") != 0 ) {
      $self->log('fatal', "Failed to symlink $targetFile -> $symlinkedFile");
    }

    $self->log('info', "Symlinked $targetFile -> $symlinkedFile");

    push @outRelativePaths, $symlinkedFile;

    $dbh->disconnect();

    sleep 5;
  }

  return @outRelativePaths;
}

sub _cleanRow {
  my ( $self, $aref ) = @_;

  # http://stackoverflow.com/questions/2059817/why-is-perl-foreach-variable-assignment-modifying-the-values-in-the-array
  for my $ele (@$aref) {
    if ( !defined($ele) || $ele eq "" ) {
      $ele = "NA";
    }
  }

  return $aref;
}

__PACKAGE__->meta->make_immutable;

1;
