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
use MooseX::Types::Path::Tiny qw/AbsFile AbsPath/;
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

# has config_file => (
#   is       => 'ro',
#   isa      => AbsFile,
#   required => 1,
#   coerce   => 1,
#   handles  => { config_file_path => 'stringify' }
# );

has out_file => (
  is        => 'ro',
  isa       => AbsPath,
  coerce    => 1,
  required  => 1,
  handles   => { output_path => 'stringify' }
);

has ignore_unknown_chr => (
  is      => 'ro',
  isa     => 'Bool',
  default => 1,
  lazy => 1,
);

has overwrite => (
  is      => 'ro',
  isa     => 'Bool',
  default => 0,
  lazy => 1,
);

# has debug => (
#   is      => 'ro',
#   isa     => 'Int',
#   default => 0,
#   lazy => 1,
# );

has snp_sites => (
  is       => 'rw',
  isa      => 'HashRef',
  init_arg => undef,
  default  => sub { {} },
  traits   => ['Hash'],
  handles  => {
    set_snp_site     => 'set',
    get_snp_site     => 'get',
    keys_snp_sites   => 'keys',
    kv_snp_sites     => 'kv',
    has_no_snp_sites => 'is_empty',
  },
  lazy => 1,
);

has genes_annotated => (
  is       => 'rw',
  isa      => 'HashRef',
  init_arg => undef,
  default  => sub { {} },
  traits   => ['Hash'],
  handles  => {
    set_gene_ann    => 'set',
    get_gene_ann    => 'get',
    keys_gene_ann   => 'keys',
    has_no_gene_ann => 'is_empty',
  },
  lazy => 1,
);

has write_batch => (
  is      => 'ro',
  isa     => 'Int',
  default => 10000,
  lazy => 1,
  init_arg => undef,
);

has genome_chrs => (
  is => 'ro',
  isa => 'ArrayRef',
  required => 1,
);

has _fileLength => (
  is => 'ro',
  isa => 'Int',
  lazy => 1,
  init_arg => undef,
  default => 0,
);

#come after all attributes to meet "requires '<attribute>'"
with 'Seq::Role::ProcessFile', 'Seq::Role::Genotypes', 'Seq::Role::Message',
#getHeaderHref
'Seq::Role::Header';

=head2 annotation_snpfile

B<annotate_snpfile> - annotates the snpfile that was supplied to the Seq object

=cut
sub BUILD {
  my $self = shift;

  #Add the first fiew field columns, whihc we always use
  #TODO: make sure these are ordered as first
  $self->addFeaturesToHeader([$self->getRequiredFileHeaderFieldNames()])
}

sub annotate_snpfile {
  my $self = shift;

  #loaded first because this also initializes our logger
  # my $annotator = Seq::Annotate->new_with_config(
  #   {
  #     configfile       => $self->config_file_path,
  #     debug            => $self->debug,
  #   }
  # );

  $self->log( 'info', 'Loading annotation data' );

  # cache import hashes that are otherwise obtained via method calls
  #   - does this speed things up?
  #
  # my $chrs_aref     = $annotator->genome_chrs;
  # my %chr_index     = map { $chrs_aref->[$_] => $_ } ( 0 .. $#{$chrs_aref} );
  # my $next_chr_href = $annotator->next_chr;
  # my $chr_len_href  = $annotator->chr_len;
  # my $genome_len    = $annotator->genome_length;

  my $headerHref        = $self->getHeaderHref;

  say "header href is";
  p $headerHref;
 
  # add header information to Seq class
  # $self->add_header_attr(@header);

  # $self->log( 'info', "Loaded assembly " . $annotator->genome_name );

  # #a file slurper that is compression-aware
  # $self->log( 'info', "Reading input file" );
  
  #my $fileLines = $self->get_file_lines( $self->snpfile_path );
  my $fh = $self->get_read_fh( $self->snpfile_path );
  # $self->log( 'info',
  #   sprintf("Finished reading input file, found %s lines", scalar @$fileLines)
  # );

  # my $defPos = -9; #default value, indicating out of bounds or not set
  # # variables
  my ( %ids, @sample_ids, @snp_annotations );
  # my ( $last_chr, $chr_offset, $next_chr, $next_chr_offset, $chr_index ) =
  #   ( $defPos, $defPos, $defPos, $defPos, $defPos );

  my (@fields, @lines, $abs_pos, $foundVarType, $wantedChr);
  my @sampleIDs;
  my %sampleIDsToIndexesMap;
  my $linesAccum;
  my $count = 0;
  my @out;

  while(<$fh>) {
    #If we don't have sampleIDs, this should be the first line of the file
    if(!@sampleIDs) {
      my $fieldsAref = $self->getCleanFields($_);
      $self->checkHeader( $fieldsAref );
      
      say "fieldsAref in first line are ";
      p $fieldsAref;
      
      %sampleIDsToIndexesMap = $self->getSampleNamesIdx( $fieldsAref );

      say "index map is";
      p %sampleIDsToIndexesMap;
      # save list of ids within the snpfile
      @sampleIDs =  sort keys %sampleIDsToIndexesMap;

      say "sampleIDs";
      p @sampleIDs;

      say "self commitEvery is " . $self->commitEvery;

      next;
    }
    
    $linesAccum .= $_;

    #$self->commitEvery from DBManager
    if($count > $self->commitEvery) {
      $self->annotateLines($linesAccum, \%sampleIDsToIndexesMap, \@sampleIDs, \@out );
      $linesAccum = '';
      $count = 0;
    }
    $count++
    #TODO: the goal after this is to print @out.
  }

  if($linesAccum) {
    $self->annotateLines($linesAccum, \%sampleIDsToIndexesMap, \@sampleIDs, \@out );
  }

  #now print
}

#after we've accumulated lines, process them
#splitting into separate function because we'll use event-driven model to run 
#this processing step
sub annotateLines {
  my ($self, $lines, $idsIdxMapHref, $sampleIdsAref, $outDataAref) = @_;

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
  
  my $linesAref = $self->getCleanFields($lines);

  my $wantedChr;
  my @inputData;
  my @positions;
  say "getting ready for linesAref";
  for my $lineFieldsAref (@$linesAref) {
    say "line collection in linesAref is";
    p $lineFieldsAref;
      #get all the fields we need
      
      #maps to
      #my ( $chr, $pos, $refAllele, $varType, $allAllelesStr, $alleleCount ) =
      my @snpFields =  map { $lineFieldsAref->[$_] } $self->allSnpFieldIdx;

      say "snpFields are";
      p @snpFields;
      exit;
      if($wantedChr && $snpFields[0] ne $wantedChr) {
        #don't sort
        #$self->annotateLinesBatch($wantedChr, \@lines, \@positions);
        #@lines = 
        my @positionData = $self->dbRead($wantedChr, \@positions, 1); 
        #copies @lines into an anonymous arrayref
        #not very efficient, but shouldn't called often
        # $self->finishAnnotatingLines($wantedChr, \@positionData, [@lines], $samplIdsAref );
        # @positions = ();
        # @lines = ();
      }

      #   # get carrier ids for variant; returns hom_ids_href for use in statistics calculator
  #   #   later (hets currently ignored)
      #$ref_allele == $snpFields[2]
      # @sampleIDargs == same as my ( $hetIds, $homIds, $sampleIDtoGenotypeMap ) =
      my @sampleIDargs =
        $self->_minor_allele_carriers( $lineFieldsAref, $idsIdxMapHref, $sampleIdsAref, 
          $snpFields[2] );

      # push @lines, \@fields;
      # push @positions, $fields[1];
      # $wantedChr = $fields[0];

      say 'sample stuff is';
      p @sampleIDargs;
    }
  }

  # if(@lines) {
  #   my @positionData = $self->dbRead($wantedChr, \@positions, 1); 
  #   $self->finishAnnotatingLines($wantedChr, \@positionData, [@lines], $samplIdsAref );
  # }
#}

sub finishAnnotatingLines {
  my ($self, $databaseDataAref, $linesAref, $sampleIdsAref) = @_;

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
  #my ( $self, $fields_aref, $ids_href, $id_names_aref, $ref_allele ) = @_;
  #to save performance, skip assignment
  #this can be called millions of time
  #in order: 
  #$self = $_[0]
  #$fields_aref = $_[1];
  #$ids_href = $_[2];
  #id_names_aref =  $_[3];
  #ref_allele = $_[4];
  my %id_genos_href = ();
  my $het_ids_str   = '';
  my $hom_ids_str   = '';
  my $id_geno;
  foreach ( @{ $_[3] } ) { # same as for my $id (@$id_names_aref);
    #$_ == $id
    $id_geno = $_[1]->[ $_[2]->{$_} ];
    # skip reference && N's && empty things
    next if ( !$id_geno || $id_geno eq $_[4] || $id_geno eq 'N' );
    # if(! $_[1]->[ $_[2]->{$_} ] || $_[1]->[ $_[2]->{$_} ] eq $_[4] || 
    # $_[1]->[ $_[2]->{$_} ] eq 'N' ) {
    #   next
    # }

    if ( $_[0]->isHet($id_geno) ) {
      $het_ids_str .= "$_;"; #same as .= "$id;";
    } elsif ( $_[0]->isHomo($id_geno) ) {
      $hom_ids_str .= "$_;";
    } else {
      $_[0]->log( 'warn', "$id_geno was not recognized, skipping" );
    }
    $id_genos_href{$_} = $id_geno;
  }
  if   ($hom_ids_str) { chop $hom_ids_str; }
  else                { $hom_ids_str = 'NA'; }
  if   ($het_ids_str) { chop $het_ids_str; }
  else                { $het_ids_str = 'NA'; }

  # return ids for printing
  return ( $het_ids_str, $hom_ids_str, \%id_genos_href );
}

__PACKAGE__->meta->make_immutable;

1;
