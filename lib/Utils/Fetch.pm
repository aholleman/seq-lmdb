use 5.10.0;
use strict;
use warnings;

package Utils::Fetch;

our $VERSION = '0.001';

# ABSTRACT: Fetch anything specified by remote_dir + remote_files 
# or sql_statement

use Mouse 2;

extends 'Utils::Base';

use namespace::autoclean;
use File::Which qw(which);
use Path::Tiny;
use YAML::XS qw/Dump/;

use Utils::SqlWriter;

use DDP;

# wget, ftp, whatever
has fetch_program => (is => 'ro', writer => '_setFetchProgram');
has fetch_program_arguments => (is => 'ro', writer => '_setFetchProgramArguments');
has fetch_command => (is => 'ro');

sub BUILD {
  my $self = shift;

  if($self->_wantedTrack->{fetch_command} || $self->_wantedTrack->{sql_statement}) {
    return;
  }

  if(!$self->fetch_program) {
    if($self->_wantedTrack->{fetch_program}) {
      $self->_setFetchProgram($self->_wantedTrack->{fetch_program});
    } else {
      my $rsync = which('rsync');
      $self->_setFetchProgram($rsync);
    }
  }

  if(!$self->fetch_program) {
    $self->log('fatal', "No fetch_program specified, and rsync not found");
    return;
  }

  if(index($self->fetch_program, 'rsync') > -1) {
    $self->{_isRsync} = 1;
  }

  if(!$self->fetch_program_arguments) {
    if($self->_wantedTrack->{fetch_program_arguments}) {
      $self->_setFetchProgramArguments($self->_wantedTrack->{fetch_program_arguments});

      $self->{_argsOutIndex} = index($self->fetch_program_arguments, "{out}");
    } elsif($self->{_isRsync}) {
      # -a explanation: http://serverfault.com/questions/141773/what-is-archive-mode-in-rsync
      # -P is --partial --progress
      $self->_setFetchProgramArguments('-aPz');
    } else {
      $self->_setFetchProgramArguments('');
    }
  }

}

########################## The only public export  ######################
sub fetch {
  my $self = shift;

  if(defined $self->_wantedTrack->{remote_files} || defined $self->_wantedTrack->{remote_dir}) {
    return $self->_fetchFiles();
  }

  if(defined $self->_wantedTrack->{sql_statement}) {
    return $self->_fetchFromUCSCsql();
  }

  if(defined $self->wantedTrack->{fetch_command}) {
    return $self->_fetchFromCommand;
  }

  $self->log('fatal', "Couldn't find either remote_files + remote_dir,"
    . " or an sql_statement for this track");
}

########################## Main methods, which do the work  ######################
sub _fetchFromCommnad {
  my $self = shift;

  my $command = $self->wantedTrack->{fetch_command};

  my $outDir = $self->_localFilesDir;

  if($self->wantedTrack->{local_files}) {
    $self->log('fatal', 'When using fetch_command, must provide local_files (glob pattern ok)');
  }
}
# These are called depending on whether sql_statement or remote_files + remote_dir given
sub _fetchFromUCSCsql {
  my $self = shift;
  
  my $sqlStatement = $self->_wantedTrack->{sql_statement};

  # What features are called according to our YAML config spec
  my $featuresKey = 'features';
  my $featuresIdx = index($sqlStatement, $featuresKey);

  if( $featuresIdx > -1 ) {
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
    chromosomes => $self->_decodedConfig->{chromosomes},
    outputDir => $self->_localFilesDir,
    compress => 1,
  });

  # Returns the relative file names
  my @writtenFileNames = $sqlWriter->fetchAndWriteSQLData();

  $self->_wantedTrack->{local_files} = \@writtenFileNames;

  $self->_wantedTrack->{fetch_date} = $self->_dateOfRun;

  $self->_backupAndWriteConfig();

  $self->log('info', "Finished fetching data from sql");
}

sub _fetchFiles {
  my $self = shift;

  my $pathRe = qr/([a-z]+:\/\/)?(\S+)/;
  my $remoteDir;
  my $remoteProtocol;

  if($self->_wantedTrack->{remote_dir}) {
    # remove http:// (or whatever protocol)
    $self->_wantedTrack->{remote_dir} =~ m/$pathRe/;

    $remoteProtocol = $self->{_isRsync} ? 'rsync://' : $1;
    $remoteDir = $2;
  }

  my $fetchArguments;

  $self->log('debug', $self->fetch_program . " args are " . $self->fetch_program_arguments);

  my $outDir = $self->_localFilesDir;

  $self->_wantedTrack->{local_files} = [];

  for my $file ( @{$self->_wantedTrack->{remote_files}} ) {
    my $remoteUrl;

    if($remoteDir) {
      $remoteUrl = $remoteProtocol . path($remoteDir)->child($file)->stringify;
       # It's an absolute remote path
    } elsif($self->{_isRsync}) {
      $file =~ m/$pathRe/;
      $remoteUrl = "rsync://" . $2;
    } else {
      $remoteUrl = $file;
    }
    
    my $fileName = $remoteDir ? $file : substr($file, rindex($file, '/'));

    # Always outputs verbose, capture the arguments
    my $command; 
    
    my $progArgs = $self->fetch_program_arguments;

    if($self->{_isRsync}) {
      $command = $self->fetch_program . " $progArgs $remoteUrl $outDir";
    } elsif($self->{_argsOutIndex} > -1) {
      substr($progArgs, $self->{_argsOutIndex}) = path($outDir)->child($fileName)->stringify;
      $command = $self->fetch_program . " $progArgs $remoteUrl";
    } else {
      $self->log('fatal', "{out} required in fetch_program_arguments. We got: $progArgs");
    }

    $self->log('info', "Fetching: " . $self->fetch_program . " cmd: " . $command);

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

    push @{ $self->_wantedTrack->{local_files} }, $fileName;

    # stagger requests to be kind to the remote server
    sleep 3;
  }

  $self->_wantedTrack->{fetch_date} = $self->_dateOfRun;

  $self->_backupAndWriteConfig();

  $self->log('info', "Finished fetching all remote files");
}

__PACKAGE__->meta->make_immutable;

1;
