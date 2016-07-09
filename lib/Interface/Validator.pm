## Interface Class
use 5.10.0;

package Interface::Validator;

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
    return path( abs_path(__FILE__) )->parent->child('./twobit');
  }, 
);

has _convertDir => (
  isa => AbsDir,
  is => 'ro',
  coerce => 1,
  init_arg => undef,
  required => 0,
  lazy => 1,
  builder => '_buildConvertDir',
);

sub _buildConvertDir {
  my $self = shift;
    
  my $path = $self->out_file->parent->child('/converted');
  $path->mkpath;

  return $path;
}

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

sub validateState {
  my $self = shift;

  $self->_validateInputFile();
}

sub _validateInputFile {
  my $self = shift;
  my $fh = $self->get_read_fh($self->snpfile);
  my $firstLine = <$fh>;

  my $headerFieldsAref = $self->getCleanFields($firstLine);

  my $inputHandler = Seq::InputFile->new();

  #last argument to not die, we want to be able to convert
  if(!@$headerFieldsAref || !$inputHandler->checkInputFileHeader($headerFieldsAref, 1) ) {
    #we assume it's not a snp file
    if(!$self->convertToPed) {
      return $self->log('fatal', "Vcf->ped conversion failed");
    }  
    
    if(!$self->convertToSnp) {
      return $self->log('fatal', "Binary plink -> Snp conversion failed");
    }
  }
  return 1;
}

sub convertToPed {
  my ($self, $attempts) = @_;

  $self->log('info', 'Converting input file to binary plink format');
  my $out = $self->_convertFileBasePath;
  return if system($self->_vcf2ped . " --vcf " . $self->snpfilePath . " --out $out");
  
  return 1;
}

# converts a binary file to snp; expects out path to be a path to folder
# containing a .bed, .bim, .fam
sub convertToSnp {
  my $self = shift;

  my $cFiles = $self->_findBinaryPlinkFiles;
  my $out = $self->_convertFileBasePath; #assumes the converter appends ".snp"
  my $twobit = $self->_twoBitDir->child($self->assembly . '.2bit')->stringify;

  return unless defined $cFiles;
  
  my @args = ( 
    '-bed ', $cFiles->{bed},
    '-bim ', $cFiles->{bim}, 
    '-fam ', $cFiles->{fam}, 
    '-out ', $out, '-two ', $twobit);

  $self->log('info', 'Converting from binary plink to snp format');

  # returns a value only upon error
  return if system($self->_ped2snp . ' convert ' . join(' ', @args) );

  #because the linkage2Snp converted auto-appends a .snp file extension
  $self->setSnpfile($out.'.snp');

  $self->log('info', 'Successfully converted to snp format');
  return 1;
}

sub _findBinaryPlinkFiles {
  my $self = shift;
  
  my $bed = path($self->_convertFileBasePath.'.bed'); 
  my $bim = path($self->_convertFileBasePath.'.bim'); 
  my $fam = path($self->_convertFileBasePath.'.fam'); 

  if($bed->is_file && $bim->is_file && $fam->is_file) {
    return {
      bed => $bed->stringify,
      bim => $bim->stringify,
      fam => $fam->stringify,
    }
  }
  $self->log('warn', 
    'Bed, bim, and/or fam don\'t exist at ' . $self->convertDir->stringify
  );
  return; 
}

1;
