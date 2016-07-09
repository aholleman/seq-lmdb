use 5.10.0;
use strict;
use warnings;

package Utils::SqlWriter;

our $VERSION = '0.001';

# ABSTRACT: Fetch and write some data using UCSC's public SQL db
use Mouse 2;

use DBI;
use namespace::autoclean;
use Time::localtime;
use Path::Tiny qw/path/;
use DDP;

with 'Seq::Role::IO', 'Seq::Role::Message';

# @param <Str> sql_statement : Valid SQL with fully qualified field names
has sql_statement => (is => 'ro', isa => 'Str', required => 1);

# @param <ArrayRef> chromosomes : All wanted chromosomes
has chromosomes => (is => 'ro', isa => 'ArrayRef', required => 1);

# Where any downloaded or created files should be saved
has outputDir => ( is => 'ro', isa => 'Str', required => 1);

# Compress the output?
has compress => ( is => 'ro', isa => 'Bool', lazy => 1, default => 0);

######################### DB Configuartion Vars #########################
my $year          = localtime->year() + 1900;
my $mos           = localtime->mon() + 1;
my $day           = localtime->mday;
my $nowTimestamp = sprintf( "%d-%02d-%02d", $year, $mos, $day );

has driver  => ( is => 'ro', isa => 'Str',  required => 1, default => "DBI:mysql" );
has host => ( is => 'ro', isa => 'Str', lazy => 1, default  => "genome-mysql.cse.ucsc.edu");
has user => ( is => 'ro', isa => 'Str', required => 1, default => "genome" );
has password => ( is => 'ro', isa => 'Str', );
has port     => ( is => 'ro', isa => 'Int', );
has socket   => ( is => 'ro', isa => 'Str', );

=method @public sub connect

  Build database object, and return a handle object

Called in: none

@params:

@return {DBI}
  A connection object

=cut

sub connect {
  my $self = shift;
  my $databaseName = shift;

  my $connection  = $self->driver;
  $connection .= ":database=$databaseName;host=" . $self->host if $self->host;
  $connection .= ";port=" . $self->port if $self->port;
  $connection .= ";mysql_socket=" . $self->port_num if $self->socket;
  $connection .= ";mysql_read_default_group=client";

  return DBI->connect( $connection, $self->user, $self->password, {
    RaiseError => 1, PrintError => 1, AutoCommit => 1
  } );
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
    # for return data
    my @sql_data = ();
    
    my $query = $self->sql_statement;

    ########### Restrict SQL fetching to just this chromosome ##############

    # Get the FQ table name (i.e hg19.refSeq instead of refSeq), to avoid
    $query =~ m/FROM\s(\S+)/i;
    my $fullyQualifiedTableName = $1;

    $query.= sprintf(" WHERE %s.chrom = '%s'", $fullyQualifiedTableName, $chr);

    my ($databaseName, $tableName) = ( split (/\./, $fullyQualifiedTableName) );

    if(!($databaseName && $tableName)) {
      $self->log('fatal', "WHERE statement must use fully qualified table name" .
        "Ex: hg38.refGene instead of refGene");
    }

    $self->log('info', "Updated sql_statement to $query");

    my $fileName = join '.', $databaseName, $tableName, $chr, $extension;
    my $timestampName = join '.', $nowTimestamp, $fileName;

    # Save the fetched data to a timestamped file, then symlink it to a non-timestamped one
    # This allows non-destructive fetching
    my $symlinkedFile = path($self->outputDir)->child($fileName)->absolute->stringify;
    my $targetFile = path($self->outputDir)->child($timestampName)->absolute->stringify;

    # prepare file handle
    my $outFh = $self->get_write_fh($targetFile);

    ########### Connect to database ##################
    my $dbh = $self->connect($databaseName);
    ########### Prepare and execute SQL ##############
    my $sth = $dbh->prepare($query) or $self->log('fatal', $dbh->errstr);
    
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

    $sth->finish();
    # Must commit before this works, or will get DESTROY before explicit disconnect()
    $dbh->disconnect();

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

    push @outRelativePaths, $fileName;

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
