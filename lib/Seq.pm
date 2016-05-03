use 5.10.0;
use strict;
use warnings;

package Seq;

our $VERSION = '0.001';

# ABSTRACT: A class for kickstarting building or annotating snpfiles
# VERSION

=head1 DESCRIPTION

  @class B<Seq>
  #TODO: Check description
  From where all annotation originates

  @example

Used in: None

Extended by: None

=cut

use Moose 2;
use MooseX::Types::Path::Tiny qw/AbsFile AbsPath AbsDir/;
use List::Util qw/first/;
#For later: move to async io
# use AnyEvent;
# use AnyEvent::IO;
# use IO::AIO;
# use Path::Tiny;
# use IO::AIO;

# use Carp qw/ croak /;
# use Cpanel::JSON::XS;
use namespace::autoclean;
use Parallel::ForkManager;

use DDP;

extends 'Seq::Base';
# use Coro;

# use Seq::Annotate;
# use Seq::Progress;

has snpfile => (
  is       => 'ro',
  isa      => AbsFile,
  coerce   => 1,
  required => 1,
  handles  => { snpfile_path => 'stringify' }
);

has out_file => (
  is        => 'ro',
  isa       => AbsPath,
  coerce    => 1,
  required  => 1,
  handles   => { output_path => 'stringify' }
);

# has ignore_unknown_chr => (
#   is      => 'ro',
#   isa     => 'Bool',
#   default => 1,
#   lazy => 1,
# );

has temp_dir => (
  is => 'ro',
  isa => AbsDir,
  lazy => 1,
  coerce => 1,
  default => '/tmp',
);

$Seq::tempOutPath = '';

#we also add a few of our own annotation attributes
#trying global prpoerties because they work a bit better with some
#multi-process perl packages
$Seq::heterozygousIdsKey = 'heterozygotes';
$Seq::compoundIdsKey = 'compoundHeterozygotes';
$Seq::homozygousIdsKey = 'homozygotes';

sub BUILD {
  my $self = shift;

  my $tempDir = $self->temp_dir ? $self->temp_dir : $self->output_file->parent;

  $Seq::tempOutPath = $tempDir->child($self->out_file->basename)->stringify;
}
#come after all attributes to meet "requires '<attribute>'"
with 'Seq::Role::ProcessFile', 'Seq::Role::Genotypes', 'Seq::Role::Message';

=head2 annotation_snpfile

B<annotate_snpfile> - annotates the snpfile that was supplied to the Seq object

=cut
# sub BUILD {
#   my $self = shift;
# }

my $pm = Parallel::ForkManager->new(10);

#TODO: Need to implement out-of-bounds check for assembly
sub annotate_snpfile {
  my $self = shift;

  $self->commitEvery(1e4);

  $self->log( 'info', 'Beginning annotation' );

  my $fh = $self->get_read_fh( $self->snpfile_path );

  my ( %ids, @sample_ids, @snp_annotations );
  # my ( $last_chr, $chr_offset, $next_chr, $next_chr_offset, $chr_index ) =
  #   ( $defPos, $defPos, $defPos, $defPos, $defPos );

  # my (@fields, @lines, $abs_pos, $foundVarType, $wantedChr);
  my @sampleIDs;
  my %sampleIDsToIndexesMap;
  my @lines;
  my $count = 0;
  my $partNumber = 0;

  our $heterozygousIdsKey;
  our $homozygousIdsKey;
  our $compoundIdsKey;

  while(<$fh>) {
    #If we don't have sampleIDs, this should be the first line of the file
    if(!@sampleIDs) {
      my $fieldsAref = $self->getCleanFields($_);
     
      $self->checkHeader( $fieldsAref );

      #needs to happen before we get into writing anything in children
      #to make sure we have one header state
      #We have a few additional fields we will be adding as pseudo-features
      $self->makeOutputHeader([$heterozygousIdsKey, $homozygousIdsKey, $compoundIdsKey]);

      %sampleIDsToIndexesMap = $self->getSampleNamesIdx( $fieldsAref );

      # save list of ids within the snpfile
      @sampleIDs =  sort keys %sampleIDsToIndexesMap;

      #We also want to add these fields to our output heade
      #for now , need to add the snp file headers after BUILD, because
      #checkHeader is what sets the file_type, which is needed for getRequiredFieldHeaderFieldNames
      #Add the first fiew field columns, whihc we always use
      #TODO: make sure these are ordered as first

      # This is now done inside of ProcessFile.pm
      # $self->addFeaturesToOutputHeader([$self->getRequiredFileHeaderFieldNames()]);

      next;
    }
    chomp;
    #$linesAccum .= $_;
    push @lines, $_;

    #$self->commitEvery from DBManager
    if($count > $self->commitEvery) {
      $partNumber++;
      $self->annotateLines(\@lines, \%sampleIDsToIndexesMap, \@sampleIDs, $partNumber);
      @lines = ();
      $count = 0;
    }
    $count++
    #TODO: the goal after this is to print @out.
  }

  if(@lines) {
    $partNumber++;
    $self->annotateLines(\@lines, \%sampleIDsToIndexesMap, \@sampleIDs, $partNumber);
  }

  $pm->wait_all_children();

  #TODO: return # of discordant bases from children if wanted

  #provided everyone finished, we will have N parts; concatenate them into the 
  #output file
  #first write the header to the output file, becuase pre-pending takes a temp
  #file step afaik

  #TODO FINISH THIS! Goal is to concatenate file parts

  $self->printHeader($self->output_path);
  my @partPaths = map { $Seq::tempOutPath . $_ } (1 .. $partNumber);
  my $concatTheseFiles = join (' ', @partPaths);

  $self->log('info', 'Concatenating output files');

  my $err = system("cat $concatTheseFiles >> " . $self->output_path);

  if($err) {
    $self->log('fatal', 'Concatenation of output file parts failed');
  }
}

#after we've accumulated lines, process them
#splitting into separate function because we'll use event-driven model to run 
#this processing step
sub annotateLines {
  $pm->start and return;
  my ($self, $linesAref, $idsIdxMapHref, $sampleIdsAref, $partNumber) = @_;

  # say "called annotateLines";
  # p $linesAref;
  # # progress counters
  state $pubProg;
  state $writeProg;

  #if (!$pubProg && $self->hasPublisher) {
    # $pubProg = Seq::Progress->new({
    #   progressBatch => 200,
    #   fileLines => scalar @$fileLines,
    #   progressAction => sub {
    #     $pubProg->recordProgress($pubProg->progressCounter);
    #     $self->publishMessage({progress => $pubProg->progressFraction } )
    #   },
    # });
  #}
  
  #if(!$writeProg) {
    # $writeProg = Seq::Progress->new({
    #   progressBatch => $self->write_batch,
    #   progressAction => sub {
    #     $self->publishMessage('Writing ' . 
    #       $self->write_batch . ' lines to disk') if $self->hasPublisher;
    #     $self->print_annotations( \@snp_annotations );
    #     @snp_annotations = ();
    #   },
    # });
 # }
  
  #my $linesAref = $self->getCleanFields($lines);

  my @output;

  my $wantedChr;
  my @inputData;
  my @positions;
  my @sampleData;
  my ( $chr, $pos, $refAllele, $varType, $allAllelesStr );
  my @fields;
  #Note: Expects first 3 fields to be chr, position, reference
  foreach (@$linesAref) {
    @fields = split(/\t/, $self->clean_line( $_ ) );

    #maps to
    #my ( $chr, $pos, $referenceAllele, $variantType, $allAllelesStr ) =
    my @snpFields = map { $fields[$_] } $self->allSnpFieldIdx;
    push @inputData, \@snpFields;

    #$snpFields[0] expected to be chr
    if($wantedChr && $snpFields[0]  ne $wantedChr) {
      #don't sort to preserve order 
      my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions, 1); 

      $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
        \@sampleData, \@output);
      @positions = ();
      @inputData = ();
      @sampleData = ();
    }

    #get all the fields we need
    $wantedChr = $snpFields[0];
    #   # get carrier ids for variant; returns hom_ids_href for use in statistics calculator
    #   later (hets currently ignored)
    #$ref_allele == $snpFields[2]
    # @sampleIDargs == same as my ( $hetIds, $homIds, $compoundsHetIds, $sampleIDtoGenotypeMap ) =
    push @sampleData, [ $self->_minor_allele_carriers( \@fields, $idsIdxMapHref, 
        $sampleIdsAref, $snpFields[2] ) ];

    #therefore input data will have
    #$snpFields[1] expected to be the position
    push @positions, $snpFields[1];

  }

  if(@positions) {
    my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions, 1); 

    $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
      \@sampleData, \@output);
  }

 # p @output;
  #exit;
  #write everything for this part
  $self->printAnnotations(\@output, \@inputData, $Seq::tempOutPath . $partNumber);

  #TODO: need also to take care of statistics stuff,
  #but that will need to wait a bit, since that will require 
  #inter-process data sharing
  $pm->finish;
}

#This iterates over some database data, and gets all of the associated track info
#it also modifies the correspoding input lines where necessary by the Indel package
sub finishAnnotatingLines {
  my ($self, $chr, $dataFromDbRef, $dataFromInputAref, $sampleGenotypesAref, $outAref) = @_;

  our $heterozygousIdsKey;
  our $homozygousIdsKey;
  our $compoundIdsKey;

  my $dataFromDbAref = ref $dataFromDbRef eq 'ARRAY' ? $dataFromDbRef : [$dataFromDbRef];

  my @trackGetters = $self->getAllTrackGetters();
  #@$dataFromDBaRef == @$dataFromInputAref
  for (my $i = 0; $i < @$dataFromDbAref; $i++) {
    push @$outAref, { map { $_->name => $_->get($dataFromDbAref->[$i], $chr) } @trackGetters };

    #$sampleGenotypesAref expected to be ( $het_ids_str, $hom_ids_str, $compounds_ids_str, \%id_genos_href );
    $outAref->[$i]{$heterozygousIdsKey} = $sampleGenotypesAref->[$i][0];
    $outAref->[$i]{$homozygousIdsKey} = $sampleGenotypesAref->[$i][1];
    $outAref->[$i]{$compoundIdsKey} = $sampleGenotypesAref->[$i][2];

    #Annotate the Indel, which is a bit like annotating a bunch of other
    #sites
    #and is held in a separate package, Sites::Indels
    #it takes the chr, and the current site's annotation data
    #then it will fetch the required sites, and get the gene track
    #TODO: finish implementing
    #$self->annotateIndel( $chr, \%singleLineOutput, $dataFromInputAref->[$i] );
    
  }

  return $outAref;

  # say "dataFromDBaRef is";
  # p $dataFromDBaRef;
  #say "processed ". $self->commitEvery . " lines";
  #   #if we wish to save cycles, can move this to original position, below
  #   #many conditionals, and then upon completion, set progress(1).
  #   $pubProg->incProgressCounter if $pubProg;
  #   #expects chomped lines

  #   # taint check the snpfile's data
    #@fields = $self->get_clean_fields($line);

  #   # process the snpfile line
    

  #   # not checking for $allele_count for now, because it isn't in use
  #   next unless $chr && $pos && $ref_allele && $var_type && $all_allele_str;
    
  

  #   # check that $chr is an allowable chromosome
  #   # decide if we plow through the error or if we stop
  #   # if we allow plow through, don't write log, to avoid performance hit
  #   if(! exists $chr_len_href->{$chr} ) {
  #     next if $self->ignore_unknown_chr;
  #     return $self->log( 'error', 
  #       sprintf( "Error: unrecognized chromosome: '%s', pos: %d", $chr, $pos )
  #     );
  #   }
  #new way:
  #if no genome_chrs specified, I think we should assume all
  #for now, just check if we have that chromosome in the YAML config
      # if( first { $chr eq $_ } @{ $self-> genome_chrs } ) {

      # }


  #   # determine the absolute position of the base to annotate
  #   if ( $chr eq $last_chr ) {
  #     $abs_pos = $chr_offset + $pos - 1;
  #   } else {
  #     $chr_offset = $chr_len_href->{$chr};
  #     $chr_index  = $chr_index{$chr};
  #     $next_chr   = $next_chr_href->{$chr};
      
  #     if ( defined $next_chr ) {
  #       $next_chr_offset = $chr_len_href->{$next_chr};
  #     } else {
  #       $next_chr        = $defPos;
  #       $next_chr_offset = $genome_len;
  #     }

  #     # check that we set the needed variables for determining position
  #     unless ( defined $chr_offset and defined $chr_index ) {
  #      return $self->log( 'error',
  #         "Error: Couldn't set 'chr_offset' or 'chr_index' for: $chr"
  #       );
  #     }
  #     $abs_pos = $chr_offset + $pos - 1;
  #   }

  #   if ( $abs_pos > $next_chr_offset ) {
  #     my $msg = "Error: $chr:$pos is beyond the end of $chr $next_chr_offset\n
  #       Did you choose the right reference assembly?";
  #     return $self->log( 'error', $msg );
  #   }

  #   # save the current chr for next iteration of the loop
  #   $last_chr = $chr;

  #   # Annotate variant sites
  #   #   - SNP and MULTIALLELIC sites are annotated individually and added to an array
  #   #   - indels are saved in an array (because deletions might be 1 off or contiguous over
  #   #     any number of bases that cannot be determined a prior) and annotated en masse
  #   #     after all SNPs are annotated
  #   #   - NOTE: the way the annotations for INS sites now work (due to changes in the
  #   #     snpfile format, we could change their annotation to one off annotations like
  #   #     the SNPs
  #   if(index($var_type, 'SNP') > -1){
  #     $foundVarType = 'SNP';
  #   } elsif(index($var_type, 'DEL') > -1) {
  #     $foundVarType = 'DEL';
  #   } elsif(index($var_type, 'INS') > -1) {
  #     $foundVarType = 'INS';
  #   } elsif(index($var_type, 'MULTIALLELIC') > -1) {
  #     $foundVarType = 'MULTIALLELIC';
  #   } else {
  #     $foundVarType = '';
  #   }

  #   if ($foundVarType) {
  #     my $record_href = $annotator->annotate(
  #       $chr,        $chr_index, $pos,            $abs_pos,
  #       $ref_allele, $foundVarType,  $all_allele_str, $allele_count,
  #       $het_ids,    $hom_ids,   $id_genos_href
  #     );
  #     if ( defined $record_href ) {
  #       if ( $self->debug > 1 ) {
  #         say 'In seq.pm record_href is';
  #         p $record_href;
  #       }
  #       push @snp_annotations, $record_href;
  #       $writeProg->incProgressCounter;
  #     }
  #   } elsif ( index($var_type, 'MESS') == -1 && index($var_type,'LOW') == -1 ) {  
  #     $self->log( 'warn', "Unrecognized variant type: $var_type" );
  #   }
  #}

  # # finished printing the final snp annotations
  # if (@snp_annotations) {
  #   $self->log('info', 
  #     sprintf('Writing remaining %s lines to disk', $writeProg->progressCounter)
  #   );

  #   $self->print_annotations( \@snp_annotations );
  #   @snp_annotations = ();
  # }

  # $self->log('info', 'Summarizing statistics');
  # $annotator->summarizeStats;

  # if ( $self->debug ) {
  #   say "The stats record after summarize is:";
  #   p $annotator->statsRecord;
  # }

  # $annotator->storeStats( $self->output_path );

  # # TODO: decide on the final return value, at a minimum we need the sample-level summary
  # #       we may want to consider returning the full experiment hash, in case we do
  # #       interesting things.
  # $self->log( 'info',
  #   sprintf('We found %s discordant_bases', $annotator->discordant_bases )
  # ) if $annotator->discordant_bases;

  # return $annotator->statsRecord;
}

# _minor_allele_carriers assumes the following spec for indels:
# Allele listed in sample column is one of D,E,I,H, or whatever single base
# codes are defined in Seq::Role::Genotypes
# However, the alleles listed in the Alleles column will not be these
# Instead, will indicate the type (- or +) followed by the number of bases created/removed rel.ref
# So the sample column gives us heterozygosity, while Alleles column gives us nucleotide composition
sub _minor_allele_carriers {
  #my ( $self, $lineFieldsAref, $idsIdxMapHref, $sampleIdsAref, $refAllele ) = @_;
  #to save performance, skip assignment
  #this can be called millions of time
  #in order: 
  #$self = $_[0]
  #$lineFieldsAref = $_[1];
  #$idsIdxMapHref = $_[2];
  #sampleIdsAref =  $_[3];
  #refAllele = $_[4];
  my %id_genos_href;
  my ($het_ids_str, $hom_ids_str, $compounds_ids_str);
  my $id_geno;
  foreach ( @{ $_[3] } ) { # same as for my $id (@$id_names_aref);
    #$_ == $id
    #same as $lineFieldsAref->[ $idsIdxMapHref->{$id} ]
    $id_geno = $_[1]->[ $_[2]->{$_} ];

    # skip if we can't find the genotype or it's reference or an N
    #$_[4] eq $refAllele
    next if ( !$id_geno || $id_geno eq $_[4] || $id_geno eq 'N' );

    #same as $self->isHet($id_geno)
    if ( $_[0]->isHet($id_geno) ) {
      $het_ids_str .= "$_;"; #same as .= "$id;";

      if( $_[0]->isCompoundHeterozygote($id_geno, $_[4] ) ) {
        $compounds_ids_str .= "$_;";
      }
    } elsif ( $_[0]->isHomo($id_geno) ) {
      $hom_ids_str .= "$_;";
    } else {
      $_[0]->log( 'fatal', "$id_geno was not either homozygous or heterozygous" );
    }
    $id_genos_href{$_} = $id_geno;
  }
  if   ($hom_ids_str) { chop $hom_ids_str; }
  if   ($het_ids_str) { chop $het_ids_str; }
  if   ($compounds_ids_str) { chop $het_ids_str; }

  # return ids for printing
  return ( $het_ids_str, $hom_ids_str, $compounds_ids_str, \%id_genos_href );
}

__PACKAGE__->meta->make_immutable;

1;