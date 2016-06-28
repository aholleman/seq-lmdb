#!/usr/bin/env perl
##############################################################################
### This program reformats VCF files for input to SeqAnt
### Follows VCF4.1 spec http://samtools.github.io/hts-specs/VCFv4.1.pdf
##############################################################################
use 5.10.0;
use strict;
use warnings;

use lib './lib';
use Cwd;
use Carp;
use Getopt::Long;
use Pod::Usage;
use File::Spec;
use List::Util qw/first /;
use Log::Any::Adapter;
use DDP;
##############################################################################
### Constants
##############################################################################

use constant VERSION => '1.0.0';
use constant PROGRAM => eval { ( $0 =~ m/(\w+\.pl)$/ ) ? $1 : $0 };

##############################################################################
### Globals
##############################################################################

my %hCmdLineOption = ();
my $sHelpHeader    = "\nThis is " . PROGRAM . " version " . VERSION . "\n";

my %iupac = (
  'G,T' => 'K',
  'T,G' => 'K',
  'A,C' => 'M',
  'C,A' => 'M',
  'A,G' => 'R',
  'G,A' => 'R',
  'C,G' => 'S',
  'G,C' => 'S',
  'A,T' => 'W',
  'T,A' => 'W',
  'C,T' => 'Y',
  'T,C' => 'Y',
  'G,G' => 'G',
  'T,T' => 'T',
  'A,A' => 'A',
  'C,C' => 'C',
  'D,D' => 'D',
  'I,I' => 'I',
  # TODO: clear with everyone; I think an Indel should be distinct from
  # del/mutation; rare but possible.
  'D,I' => 'J',
  'I,D' => 'J',
);
# set hets ; doing both permutations prob. unnec; GT should go in numerical asc.
foreach (qw/A T C G/) {
  $iupac{"$_,D"} = 'E';
  $iupac{"D,$_"} = 'E';
  $iupac{"I,$_"} = 'H';
  $iupac{"$_,I"} = 'H';
}
##############################################################################
### Main
##############################################################################

# note on interpolation vs join vs concatenation:
# in perl, all compile to the same optree: http://www.perlmonks.org/?node_id=964608
my ( $sInFile, $sOutFile, $bVerbose );
GetOptions(
  \%hCmdLineOption,
  'infile|i=s'  => \$sInFile,
  'outfile|o=s' => \$sOutFile,
  'help',
  'man'
) or pod2usage(2);

pod2usage( -msg => $sHelpHeader, -exitval => 1 )
  if $hCmdLineOption{'help'} || !$sInFile || !$sOutFile;
pod2usage( -exitval => 0, -verbose => 2 )
  if $hCmdLineOption{'man'};

File::Spec->canonpath($sOutFile);

my $log_file = join '.', $sOutFile, 'snp_conversion', 'log';

Log::Any::Adapter->set( 'File', $log_file );
my $log = Log::Any->get_logger();

my ( $fpIn, $fpOut );
if ( !$sInFile ) {
  $fpIn = \*STDIN;
}
else {
  unless ( open( $fpIn, "<$sInFile" ) ) {
    my $err = "\tError : Cannot open $sInFile for reading .....\n";
    $log->error($err);
    die $err;
  }
}

unless ( open( $fpOut, ">$sOutFile" ) ) {
  my $err = "\tError : Cannot open $sInFile for reading .....\n";
  $log->error($err);
  die $err;
}

my $outHeaders = "Fragment\tPosition\tReference\tAlleles\tAllele_Counts\tType";
my @sampleIds;
my @samplesIdxs;

LOOP_FILE: while (<$fpIn>) {
  chomp;
  next if ( $_ =~ /^##/ );

  my @row = split(/\t/);
  #header containing sample pos begins with #CHROM
  if ( $_ =~ /^#C/ ) {
    # if range is > $@row, will modify @row, but doesn't matter here
    @samplesIdxs = 9 ... $#row;
    @sampleIds   = @row[@samplesIdxs];

    croak "No samples found" unless scalar @sampleIds;

    foreach (@sampleIds) { $outHeaders .= "\t$_\t"; }

    $log->debug("output headers are $outHeaders");

    say $fpOut $outHeaders;
    next LOOP_FILE;
  }
  # ($sFragId, $nBasePos, $sId, $sRefBase, $sInBase, $sQual, $sFilter, $sInfo,
  # 	$sFormat, @aSampleCalls) = split(/\t/);

  #this formula is nonsense: $sqal = $sQual / 100 ... it's a phred score

  #5th row is ALT (all sample alleles)
  next LOOP_FILE unless $row[4] ne '.';

  my ( $allelesAref, $ac, $type ) = _getBases( \@row );

  my $sampleStr = _formatSampleString( \@row, $allelesAref );

  say $fpOut "$row[0]\t$row[1]\t$allelesAref->[0]\t"
    . join( ',', @$allelesAref[ 1 ... $#$allelesAref ] )
    . "\t$ac\t$type\t$sampleStr";
}

###Private###

#for now following exac_to_snp.pl in assuming no het reference base
my $ambigBase = 'N';
my $alleles;

sub _getBases {
  my ($rowAref) = @_;

  my @allelesA = split( ',', $rowAref->[4] );
  my $ref = $rowAref->[3];

  # check if reference is het, to see if something strange
  # TODO: Is this a real poss? handle?
  unless ( index( $ref, ',' ) == -1 ) {
    $log->error( 'Reference is het or has unexpected comma:' . join( '\t', @$rowAref ) );
    croak;
  }
  my $type = 'SNP';

  my $refLength = length $ref;

  # TODO: implement the count check, but the Clarity vcf doesn't use AC field.
  #my $acIdx = first { $rowAref->[$_] =~ m\AC=\ } 1 .. $#$rowAref;
  my $rc = scalar @allelesA;

  my $ac;
  my @outAlleles = ($ref);
  # change from dave's only call multiallelic if non-snps present...
  # TOOD: is this desirable?
  my %newTypes;
  my $alleleLength;
  foreach (@allelesA) {
    $alleleLength = length $_;
    if ( $alleleLength > $refLength ) {
      $newTypes{INS} = 'INS';
      $_ = 'I';
    }
    elsif ( $alleleLength < $refLength ) {
      $newTypes{DEL} = 'DEL';
      $_ = 'D';
    }
    $rc-- unless ( $_ eq $ref );

    push( @outAlleles, $_ );
  }
  $ac = "$rc, " . scalar @allelesA - $rc;
  #TODO: should multiallelic be determined by sample composition instead?
  my @newTypesKeys = keys %newTypes;
  if ( scalar @newTypesKeys > 1 ) {
    $type = 'MULTIALLELIC';
  }
  elsif ( scalar @newTypesKeys == 1 ) {
    $type = $newTypes{ $newTypesKeys[0] };
  }

  return ( \@outAlleles, $ac, $type );
}

sub _formatSampleString {
  my ( $rowAref, $allelesAref ) = @_;

  #may be undefined, AC is optional
  my $out = '';
  #we don't need qual for the entire expriment

  #my $qual = 1 - 10 ** (-$rowAref->[5]/10);
  my @format = split( ':', $rowAref->[8] );

  # format not guaranteed same for every sample, so can't do this once
  # but spec doesn't seem to state this must be true, which is ...
  # states: the same types of data must be present for all samples
  # First a FORMAT field is given specifying the data types and order
  # (colon-separated alphanumeric String). This is followed by one field per
  # sample, with the colon-separated data in this field corresponding to the
  # types specified in the format
  # can never be first
  my $gqIdx = first { $format[$_] eq 'GQ' } 1 .. $#format;

  foreach ( @$rowAref[@samplesIdxs] ) {
    my @fields = split(':');
    # / for phased, | for unphased ; genotype always first (when genotypes avail)
    my @genotype = split( '/|', $fields[0] );

    # if it's a haploid call, e.g 1:SOME_QUALITY_SCORE, assume correct
    foreach (@genotype) {
      # if data missing, seen as '.', call N
      if ( $_ eq '.' ) {
        $log->debug(
          "Calling ambiguous genotype for sample $_
					because of missing genotype (e.g '.''); row is " . join( "\t", @$rowAref )
        );
        $out = 'N,';
        last;
      }
      $out .= "$allelesAref->[$_],";
    }
    chop($out);

    if ( length $out == 1 ) {
      $log->debug( "Calling haploid for sample $_; row is " . join( "\t", @$rowAref ) );
    }
    else {
      $out = $iupac{$out};
    }
    $log->error( 'No out found for row ' . join( '\t', @$rowAref ) ) unless $out;

    if ($gqIdx) {
      #phred -10*log10(Prob{mistake} )
      $out .= sprintf( "\t%.1f", 1 - 10**( -$fields[$gqIdx] / 10 ) );
    }
    else {
      $out .= "\t1.0";
    }
  }
  return $out;
}
exit;

##################################################################################
### POD Documentation
##################################################################################

# could be triploid
#if(scalar @genotype > 2) {
# 	$log->error("more than more than 1 genotype or geno. delim. found in $_");
# }
__END__

=head1 NAME

Vcf2SeqAnt_SNP.pl - This program reformats vcf format file to seqant input snp  list file.

=head1 SYNOPSIS

    Vcf2SeqAnt_SNP.pl --i <input_file> --o <output_file> [--v]

    parameters in [] are optional
    do NOT type the carets when specifying options

=head1 OPTIONS

    --i <input_file>        	= input file.
    
    --o <output_file>        	= output file.
	
    --v                     	= generate runtime messages. Optional

=head1 AUTHOR
	
 Alex Kotlar
 inspired by Dave Cutler's exac_to_snp; argv/PDO boilerplate borrowed from Vcf2SeqAnt_SNP.pl by Matthew Ezewudo
 Zwick Lab (http://genetics.emory.edu/labs/index.php?lab=44)
 Department of Human Genetics
 Emory University School of Medicine
 Whitehead Biomedical Research Center, Suite 341
 Atlanta, GA 30322

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2015 Michael E Zwick (<mzwick@genetics.emory.edu>). All rights
reserved.

This program is free software; you can distribute it and/or modify it under the
same terms as GNU GPL 3.0.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or FITNESS
FOR A PARTICULAR PURPOSE. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS
BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

		  
		  
			
			     
