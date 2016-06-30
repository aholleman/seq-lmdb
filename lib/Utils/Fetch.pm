use 5.10.0;
use strict;
use warnings;

package Utils::Fetch;

our $VERSION = '0.001';

# ABSTRACT: Fetch anything specified by remote_dir + remote_files 
# or sql_statement

use Moose 2;

extends 'Utils::Base';

use namespace::autoclean;
use File::Which qw(which);
use Path::Tiny;
use YAML::XS qw/Dump/;

use Utils::SqlWriter;
use DDP;

########################## The only public export  ######################
sub fetch {
  my $self = shift;

  if(defined $self->_wantedTrack->{remote_files} && defined $self->_wantedTrack->{remote_dir}) {
    return $self->_fetchFiles();
  }

  if(defined $self->_wantedTrack->{sql_statement}) {
    return $self->_fetchFromUCSCsql();
  }

  $self->log('fatal', "Couldn't find either remote_files + remote_dir,"
    . " or an sql_statement for this track");
}

########################## Main methods, which do the work  ######################

# These are called depending on whether sql_statement or remote_files + remote_dir given
sub _fetchFromUCSCsql {
  my $self = shift;
  
  my $sqlStatement = $self->_wantedTrack->{sql_statement};

  # What features are called according to our YAML config spec
  my $featuresKey = 'features';

  my $featuresIdx = index($sqlStatement, $featuresKey);
  my $asteriskIdx = index($sqlStatement, '*');

  if($asteriskIdx > -1 && $featuresIdx > -1) {
    $self->log('fatal', "Can't SELECT both 'features' and '*', is ambiguous");
  }

  if(!$asteriskIdx && !$featuresIdx) {
    $self->log('fatal', "SELECT statement specify either 'features' or '*");
  }

  if($featuresIdx) {
    if(! @{$self->_wantedTrack->{features}} ) {
      $self->log('fatal', "Requires features if sql_statement speciesi SELECT features")
    }

    my $trackFeatures;
    foreach(@{$self->_wantedTrack->{features}}) {
      # YAML config spec defines optional type on feature names, so some features
      # Can be hashes. Take only the feature name, ignore type, UCSC doesn't use them
      my $featureName;
      
      if(ref $_) {
        ($featureName) = %{$_};
      } else {
        $featureName = $_;
      }

      $trackFeatures .= $featureName . ',';
    }

    chop $trackFeatures;

    substr($sqlStatement, $featuresIdx, length($featuresKey) ) = $trackFeatures;
  }

  my $sqlWriter = Utils::SqlWriter->new({
    sql_statement => $sqlStatement,
    assembly => $self->_decodedConfig->{assembly},
    chromosomes => $self->_decodedConfig->{genome_chrs},
    outputDir => $self->_localFilesDir,
    name => $self->_wantedTrack->{name},
    compress => 1,
  });

  # Returns the relative file names
  my @writtenFileNames = $sqlWriter->fetchAndWriteSQLData();

  $self->_wantedTrack->{local_files} = \@writtenFileNames;

  $self->_backupAndWriteConfig();

  $self->log('info', "Finished fetching data from sql");
}

sub _fetchFiles {
  my $self = shift;

  my $rsync = which 'rsync';

  if(!$rsync) {
    $self->log('fatal', "Couldn't find rsync");
  }

  $self->log('debug', "Fetching remote data from " . $self->_wantedTrack->{remote_dir});

  # remove http:// (or whatever protocol)
  $self->_wantedTrack->{remote_dir} =~ m/(\S+:\/\/)*(\S*)/;

  my $remoteDir = $2;

  # -a explanation: http://serverfault.com/questions/141773/what-is-archive-mode-in-rsync
  my $args = '-a' . ($self->compress ? 'z' : '') . ($self->debug ? ' --progress' : '') 
    . ' --ignore-existing';

  $self->log('debug', "rsync args are $args");

  my $outPath = $self->_localFilesDir;

  $self->_wantedTrack->{local_files} = [];

  for my $file ( @{$self->_wantedTrack->{remote_files}} ) {
    $self->log('debug', "outPath is $outPath");

    my $remotePath = path($remoteDir)->child($file)->stringify;

    # Always outputs verbose, capture the arguments
    my $command = "$rsync $args rsync://$remotePath $outPath";

    $self->log('info', "rsync cmd: " . $command );

    # http://stackoverflow.com/questions/11514947/capture-the-output-of-perl-system
    open(my $fh, "-|", "$command") or $self->log('fatal', "Couldn't fork: $!\n");

    my $progress;
    while(<$fh>) {
      if($self->debug) { say $_ } # we may want to watch progress in stdout
      $self->log('info', $_);
    }
    close($fh);

    my $exitStatus = $?;

    if($exitStatus != 0) {
      $self->log('fatal', "Failed to fetch $file");
    }

    push @{ $self->_wantedTrack->{local_files} }, $file;

    # stagger requests to be kind to the remote server
    sleep 3;
  }

  $self->_backupAndWriteConfig();

  $self->log('info', "Finished fetching all remote files");
}

__PACKAGE__->meta->make_immutable;

1;
