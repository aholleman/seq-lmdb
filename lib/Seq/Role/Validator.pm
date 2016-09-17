## Interface Class
use 5.10.0;

package Seq::Role::Validator;

use Mouse::Role;
use namespace::autoclean;

#also prrovides ->is_file function
use Types::Path::Tiny qw/File AbsFile AbsPath AbsDir/;

use DDP;

use Path::Tiny;
use Cwd 'abs_path';

use YAML::XS;
use Archive::Extract;
use Try::Tiny;
use File::Which;
use Carp qw(cluck confess);

use Seq::InputFile;

with 'Seq::Role::IO', 'Seq::Role::Message';

has assembly => (is => 'ro', required => 1);

has _vcfConverterParth => (
  is       => 'ro',
  isa      => AbsFile,
  init_arg => undef,
  coerce   => 1,
  required => 1,
  default  => sub {
    return which('plink');
  },
  handles => {
    _vcf2ped => 'stringify',
  },
);

has _binaryPedConverterPath => (
  is       => 'ro',
  isa      => AbsFile,
  init_arg => undef,
  coerce   => 1,
  required => 1,
  default  => sub {
    return which('linkage2Snp');
  },
  handles => {
    _ped2snp => 'stringify',
  },
);

has _twoBitDir => (
  is       => 'ro',
  isa      => AbsPath,
  init_arg => undef,
  required => 1,
  default  => sub {
    return path( abs_path(__FILE__) )->parent->child('./2bit');
  }, 
);

has _inputFileBaseName => (
  isa => 'Str',
  is => 'ro',
  init_arg => undef,
  required => 0,
  lazy => 1,
  default => sub {
    my $self = shift;
    return $self->snpfile->basename(qr/\..*/);
  },
);

has _convertFileBase => (
  isa => AbsPath,
  is => 'ro',
  init_arg => undef,
  required => 0,
  lazy => 1,
  handles => {
    _convertFileBasePath => 'stringify',
  },
  default => sub {
    my $self = shift;
    return $self->_convertDir->child($self->_inputFileBaseName);
  },
);

sub _getConvertDir {
  my ( $self, $dir ) = @_;
  
  my $path = $dir->child('/converted');
  $path->mkpath;

  return $path;
}

sub validateInputFile {
  my ( $self, $outDir, $inputFileAbsPath ) = @_;

  if(!ref $outDir) {
    $outDir = path($outDir);
  }

  if(!ref $inputFileAbsPath) {
    $inputFileAbsPath = path($inputFileAbsPath);
  }

  say "input file name is";
  p $inputFileAbsPath;

  my $convertDir = $self->_getConvertDir($outDir);

  my $fh = $self->get_read_fh($inputFileAbsPath);
  my $firstLine = <$fh>;

  my $headerFieldsAref = $self->getCleanFields($firstLine);

  my $inputHandler = Seq::InputFile->new();

  #last argument to not die, we want to be able to convert
  if(!defined $headerFieldsAref || !$inputHandler->checkInputFileHeader($headerFieldsAref, 1) ) {
    #we assume it's not a snp file
    $self->log('info', 'Converting input file to binary plink format');

    my ($err, $convertBaseAbsPath) = $self->convertToPed($convertDir, $inputFileAbsPath);

    if ($err) {
      $self->log('warn', "Vcf->ped conversion failed with '$err'");

      return ($err, undef);
    }  
    
    $self->log('info', 'Converting from binary plink to snp format');

    ($err, my $updatedSnpFileName) = $self->convertToSnp($convertBaseAbsPath);

    if ($err) {
      $self->log('warn', "Binary plink -> Snp conversion failed with '$err'");

      return ($err, undef);
    }

    $self->log('info', 'Successfully converted to snp format');

    # Update the input file we return, to the path of the converted .snp file
    $inputFileAbsPath = $updatedSnpFileName;
  }

  return (0, $inputFileAbsPath);
}

# @return <Path::Tiny> $convertBaseAbsPath : the absolute path to the base name
# for which plink makes $convertBaseAbsPath.bed/.bim/.fam
sub convertToPed {
  my ($self, $convertDir, $inputFileAbsPath) = @_;

  if(!ref $inputFileAbsPath) {
    $inputFileAbsPath = path($inputFileAbsPath);
  }

  my $outBaseName = $inputFileAbsPath->basename(qr/\.vcf.*/);

  my $convertBaseAbsPath = $convertDir->child($outBaseName)->stringify;

  $self->log('debug', "convert base path is $convertBaseAbsPath");
    
  my $err = system($self->_vcf2ped . " --vcf " . $inputFileAbsPath->stringify
    . " --out $convertBaseAbsPath --allow-extra-chr");
  
  if($err) {
    return ($!, undef);
  }

  return (0, $convertBaseAbsPath);
}

# converts a binary file to snp; expects out path to be a path to folder
# containing a .bed, .bim, .fam
# <String> $convertBasePath : /path/to/fileBaseNam
# @out <Array> (<Str> error, <Path::Tiny> /path/to/fileBaseName.snp)
sub convertToSnp {
  my ($self, $convertBaseAbsPath) = @_;

  my ($err, $cFiles) = $self->_findBinaryPlinkFiles($convertBaseAbsPath);

  if($err ) {
    return ($err, undef);
  }

  my $twobit = $self->_twoBitDir->child($self->assembly . '.2bit')->stringify;

  my @args = ( 
    '-bed ', $cFiles->{bed},
    '-bim ', $cFiles->{bim}, 
    '-fam ', $cFiles->{fam}, 
    '-out ', $convertBaseAbsPath, '-two ', $twobit);

  # returns a value only upon error
  $err = system($self->_ped2snp . ' convert ' . join(' ', @args) );

  if($err) {
    return ($!, undef);
  }

  my $snpPath = path($convertBaseAbsPath . '.snp');

  if(!$snpPath->is_file) {
    $self->log('warn', 'convertToSnp failed to make snp file');
    return ('convertToSnp failed to make snp file', undef);
  }

  say "converted file name is";
  p $snpPath;

  #because the linkage2Snp converted auto-appends a .snp file extension
  return (0, $snpPath);
}

sub _findBinaryPlinkFiles {
  my ($self, $convertBasePath ) = @_;
    
  if(ref $convertBasePath) {
    $convertBasePath = $convertBasePath->stringify;
  }

  my $bed = $convertBasePath . '.bed';

  say "bed is";
  p $bed;

  my $bim = $convertBasePath . '.bim'; 
  my $fam = $convertBasePath . '.fam';

  if(path($bed)->is_file && path($bim)->is_file && path($fam)->is_file) {
    return (undef, { bed => $bed, bim => $bim, fam => $fam} );
  }

  $self->log('warn', "Bed, bim, and/or fam don\'t exist for base path $convertBasePath");

  return ("Bed, bim, and/or fam don\'t exist for base path $convertBasePath", undef); 
}

1;
