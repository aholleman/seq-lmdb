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

sub validateInputFile {
  my $self = shift;

  my $fh = $self->get_read_fh($self->snpfile);
  my $firstLine = <$fh>;

  my $headerFieldsAref = $self->getCleanFields($firstLine);

  my $inputHandler = Seq::InputFile->new();

  # This may be updated
  my $snpFilePath = $self->snpfilePath;

  #last argument to not die, we want to be able to convert
  if(!defined $headerFieldsAref || !$inputHandler->checkInputFileHeader($headerFieldsAref, 1) ) {
    #we assume it's not a snp file
    $self->log('info', 'Converting input file to binary plink format');

    my $err = $self->convertToPed;

    if ($err) {
      $self->log('fatal', "Vcf->ped conversion failed with '$err'");

      return ($err, undef);
    }  
    
    $self->log('info', 'Converting from binary plink to snp format');

    ($err, $snpFilePath) = $self->convertToSnp;

    $self->log('info', 'Successfully converted to snp format');

    if ($err) {
      $self->log('fatal', "Binary plink -> Snp conversion failed with '$err'");

      return ($err, undef);
    }
  }

  return (undef, $snpFilePath);
}

sub convertToPed {
  my ($self, $attempts) = @_;
  
  my $out = $self->_convertFileBasePath;
  
  my $err = system($self->_vcf2ped . " --vcf " . $self->snpfilePath . " --out $out --allow-extra-chr");
  
  if($err) {
    return $!;
  }

  return 0;
}

# converts a binary file to snp; expects out path to be a path to folder
# containing a .bed, .bim, .fam
sub convertToSnp {
  my $self = shift;

  my $cFiles = $self->_findBinaryPlinkFiles;
  my $out = $self->_convertFileBasePath; #assumes the converter appends ".snp"
  my $twobit = $self->_twoBitDir->child($self->assembly . '.2bit')->stringify;

  if(! defined $cFiles ) {
    return ("Missing binary plink files (.bed, .bim, .fam)", undef);
  }
  
  my @args = ( 
    '-bed ', $cFiles->{bed},
    '-bim ', $cFiles->{bim}, 
    '-fam ', $cFiles->{fam}, 
    '-out ', $out, '-two ', $twobit);

  # returns a value only upon error
  my $err = system($self->_ped2snp . ' convert ' . join(' ', @args) );

  if($err) {
    return ($!, undef);
  }

  #because the linkage2Snp converted auto-appends a .snp file extension
  
  $out = "$out.snp";

  return (0, $out);
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
