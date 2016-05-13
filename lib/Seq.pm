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

use Path::Tiny;
use File::Temp qw/ tempdir /;
use namespace::autoclean;
use Parallel::ForkManager;

use DDP;

use MCE::Loop;
use MCE::Candy;
use MCE::Shared;

extends 'Seq::Base';

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

$Seq::tempOutPath = '';

#we also add a few of our own annotation attributes
#trying global prpoerties because they work a bit better with some
#multi-process perl packages
$Seq::heterozygousIdsKey = 'heterozygotes';
$Seq::compoundIdsKey = 'compoundHeterozygotes';
$Seq::homozygousIdsKey = 'homozygotes';

sub BUILD {
  my $self = shift;

  $Seq::tempOutPath = path( tempdir( CLEANUP => 1 ) )->child($self->out_file->basename)->stringify;
}
#come after all attributes to meet "requires '<attribute>'"
with 'Seq::Role::ProcessFile', 'Seq::Role::Genotypes', 'Seq::Role::Message';

=head2 annotation_snpfile

B<annotate_snpfile> - annotates the snpfile that was supplied to the Seq object

=cut
# sub BUILD {
#   my $self = shift;
# }

#my $pm = Parallel::ForkManager->new(40);

#MCE version
sub annotate_snpfile {
  our $self = shift;

  $self->log( 'info', 'Beginning annotation' );

  #this is much slower
  #my $fh = $self->get_read_fh( $self->snpfile_path );

  open(my $fh, '<', $self->snpfile_path);
  # my $count = 0;
  our $heterozygousIdsKey;
  our $homozygousIdsKey;
  our $compoundIdsKey;
  our $partNumber = 0;
  
  our $sampleIDsToIndexesMap;
  our $taint_check_regex = $self->taint_check_regex; 
  our $endOfLineChar = $self->endOfLineChar;
  our $delimiter = $self->delimiter;

  our $sampleIDaref;
  
  my $firstLine = $fh->getline();

  chomp $firstLine;
  if ( $firstLine =~ m/$taint_check_regex/xm ) {
    $firstLine = [ split $delimiter, $1 ];

    $self->checkHeader($firstLine);

    $self->makeOutputHeader([$heterozygousIdsKey, $homozygousIdsKey, $compoundIdsKey]);

    $sampleIDsToIndexesMap = { $self->getSampleNamesIdx( $firstLine ) };

    # save list of ids within the snpfile
    $sampleIDaref =  [ sort keys %$sampleIDsToIndexesMap ];

  } else {
    $self->log('fatal', "First line of input file has illegal characters");
  }

  open(my $outFh, '>', $self->output_path);
  say $outFh $self->makeHeaderString();

  MCE::Loop::init {
    chunk_size => 8100, #max i think
    max_workers => 30,
    gather => MCE::Candy::out_iter_fh($outFh),
  };

  #our $taint_check_regex = qr{\A([\+\,\.\-\=\:\/\t\s\w\d]+)\z};
  mce_loop_f {
   my ( $mce, $chunk_ref, $chunk_id ) = @_;

   chomp @{$_};

   if($chunk_id == 1) {
    shift @{$_};
   }

    for my $line (@{$_}) {
      if ( $line =~ m/$taint_check_regex/xm ) {
        $line = [ split $delimiter, $1 ];
      } else {
        $self->log('fatal', "$line contains characters we don't accept")
      }
    }

    #$self->annotateLines($_, $sampleIDsToIndexesMap, $sampleIDaref, $chunk_id);
    MCE->gather($chunk_id, $self->annotateLines($_, $sampleIDsToIndexesMap, $sampleIDaref, $chunk_id));
  } $fh;

  #get anything left over
  # if(@lines) {
  #   say "stuff remains";
  #   $partNumber++;
  #   $self->annotateLines(\@lines, \%sampleIDsToIndexesMap, \@sampleIDs, $partNumber);
  # }

 # $pm->wait_all_children();

  #TODO: return # of discordant bases from children if wanted

  #provided everyone finished, we will have N parts; concatenate them into the 
  #output file
  #first write the header to the output file, becuase pre-pending takes a temp
  #file step afaik

  

  # my @partPaths = map { $Seq::tempOutPath . $_ } (1 .. $lastChunkID);
  # my $concatTheseFiles = join (' ', @partPaths);

  # $self->log('info', 'Concatenating output files');

  # my $err = system("cat $concatTheseFiles >> " . $self->output_path);

  # if($err) {
  #   $self->log('fatal', 'Concatenation of output file parts failed');
  # }
}

#TODO: Need to implement unknown chr check, LOW/MESS check
# sub annotate_snpfile {
#   my $self = shift;

#   $self->commitEvery(1e4);

#   $self->log( 'info', 'Beginning annotation' );

#   my $fh = $self->get_read_fh( $self->snpfile_path );

#   my ( %ids, @sample_ids, @snp_annotations );
#   my @sampleIDs;
#   my %sampleIDsToIndexesMap;
#   my @lines;
#   my $count = 0;
#   my $partNumber = 0;

#   our $heterozygousIdsKey;
#   our $homozygousIdsKey;
#   our $compoundIdsKey;

#   while (my $line = $fh->getline() ) {
#     #If we don't have sampleIDs, this should be the first line of the file
#     if(!@sampleIDs) {
#       my $fieldsAref = $self->getCleanFields($line);
     
#       $self->checkHeader( $fieldsAref );

#       #needs to happen before we get into writing anything in children
#       #to make sure we have one header state
#       #We have a few additional fields we will be adding as pseudo-features
#       $self->makeOutputHeader([$heterozygousIdsKey, $homozygousIdsKey, $compoundIdsKey]);

#       %sampleIDsToIndexesMap = $self->getSampleNamesIdx( $fieldsAref );

#       # save list of ids within the snpfile
#       @sampleIDs =  sort keys %sampleIDsToIndexesMap;

#       next;
#     }
#     chomp $line;
#     push @lines, $line;

#     #$self->commitEvery from DBManager
#     if($count > $self->commitEvery) {
#       $partNumber++;
      
#       $self->annotateLines(\@lines, \%sampleIDsToIndexesMap, \@sampleIDs, $partNumber);
      
#       @lines = ();
#       $count = 0;
#     }
#     $count++
#   }

#   #get anything left over
#   if(@lines) {
#     $partNumber++;
#     $self->annotateLines(\@lines, \%sampleIDsToIndexesMap, \@sampleIDs, $partNumber);
#   }

#   $pm->wait_all_children();

#   #TODO: return # of discordant bases from children if wanted

#   #provided everyone finished, we will have N parts; concatenate them into the 
#   #output file
#   #first write the header to the output file, becuase pre-pending takes a temp
#   #file step afaik

#   $self->printHeader($self->output_path);
#   my @partPaths = map { $Seq::tempOutPath . $_ } (1 .. $partNumber);
#   my $concatTheseFiles = join (' ', @partPaths);

#   $self->log('info', 'Concatenating output files');

#   my $err = system("cat $concatTheseFiles >> " . $self->output_path);

#   if($err) {
#     $self->log('fatal', 'Concatenation of output file parts failed');
#   }
# }

#after we've accumulated lines, process them
sub annotateLines {
  #$pm->start and return;
  my ($self, $linesAref, $idsIdxMapHref, $sampleIdsAref, $partNumber) = @_;

  #die;
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
  for my $fieldsAref (@$linesAref) {
   # @fields = split(/\t/, $self->clean_line( $line ) );

   # say "field is ;";
   # p $fieldsAref;
    #maps to
    #my ( $chr, $pos, $referenceAllele, $variantType, $allAllelesStr ) =
    my @snpFields = map { $fieldsAref->[$_] } $self->allSnpFieldIdx;
    
    push @inputData, \@snpFields;

    #$snpFields[0] expected to be chr
    if($wantedChr && $snpFields[0] ne $wantedChr) {
      #don't sort to preserve order 
      my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions, 1); 

      $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
        \@sampleData, \@output);
      @positions = ();
      @inputData = ();
      @sampleData = ();
    }

    $wantedChr = $snpFields[0];
    
    # get carrier ids for variant; returns hom_ids_href for use in statistics calculator

    #$ref_allele == $snpFields[2]
    my $sampleIDtypesAref; 
    for my $id ( @$sampleIdsAref ) { # same as for my $id (@$id_names_aref);
      my $geno = $fieldsAref->[ $idsIdxMapHref->{$id} ];

      if( $geno eq 'N' || $geno eq $snpFields[2] ) {
        next;
      }

      if ( $self->isHet($geno) ) {
        $sampleIDtypesAref->[0] .= "$id;";

        if( $self->isCompoundHeterozygote($geno, $snpFields[2] ) ) {
          $sampleIDtypesAref->[2] .= "$id;";
        }
      } elsif( $self->isHomo($geno) ){
        $sampleIDtypesAref->[1] .= "$id;";
      } else {
        $self->log( 'fatal', "$geno wasn't homozygous or heterozygous" );
      }
       $sampleIDtypesAref->[3]{$id} = $geno;
    }
    if   ($sampleIDtypesAref->[0]) { chop $sampleIDtypesAref->[0]; }
    if   ($sampleIDtypesAref->[1]) { chop $sampleIDtypesAref->[1]; }
    if   ($sampleIDtypesAref->[2]) { chop $sampleIDtypesAref->[2]; }

    push @sampleData, $sampleIDtypesAref;
    # if perf identical, could use: 
    # @sampleIDargs == same as my ( $hetIds, $homIds, $compoundsHetIds, $sampleIDtoGenotypeMap ) =
    # push @sampleData, [ $self->_minor_allele_carriers( \@fields, $idsIdxMapHref, 
    #     $sampleIdsAref, $snpFields[2] ) ];

    #$snpFields[1] expected to be the relative position
    #we store everything 0-indexed, so substract 1
    push @positions, $snpFields[1] - 1;

  }

  #finish anything left over
  if(@positions) {
    my $dataFromDatabaseAref = $self->dbRead($wantedChr, \@positions, 1); 

    $self->finishAnnotatingLines($wantedChr, $dataFromDatabaseAref, \@inputData, 
      \@sampleData, \@output);
  }

  #write everything for this part
  return $self->makeAnnotationString(\@output, \@inputData);

  #TODO: need also to take care of statistics stuff,
  #but that will need to wait a bit, since that will require 
  #inter-process data sharing
  #$pm->finish;
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
  for (my $i = 0; $i < @$dataFromInputAref; $i++) {
    if(!$dataFromDbAref->[$i] ) {
      $self->log('fatal', "$chr: " . $dataFromInputAref->[$i][1] . " not found.
        You may have chosen the wrong assembly");
    }

    #some tracks may also want the alternative alleles, so give those as last arg
    push @$outAref, { 
      map { 
        $_->name => $_->get($dataFromDbAref->[$i], $chr, $dataFromInputAref->[2]) } 
      @trackGetters };

    #$sampleGenotypesAref expected to be ( $het_ids_str, $hom_ids_str, $compounds_ids_str, \%id_genos_href );
    $outAref->[$i]{$heterozygousIdsKey} = $sampleGenotypesAref->[$i][0];
    $outAref->[$i]{$homozygousIdsKey} = $sampleGenotypesAref->[$i][1];
    $outAref->[$i]{$compoundIdsKey} = $sampleGenotypesAref->[$i][2];

    #Could check for discordant bases here
    
    #Annotate the Indel, which is a bit like annotating a bunch of other
    #sites
    #and is held in a separate package, Sites::Indels
    #it takes the chr, and the current site's annotation data
    #then it will fetch the required sites, and get the gene track
    #TODO: finish implementing
    #$self->annotateIndel( $chr, \%singleLineOutput, $dataFromInputAref->[$i] );
    
  }

  return $outAref;
}

__PACKAGE__->meta->make_immutable;

1;