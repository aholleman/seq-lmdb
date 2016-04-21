use 5.10.0;
use strict;
use warnings;

#Breaking this thing down to fit in the new contxt
#based on Seq::Gene in (kyoto-based) seq branch
#except _get_gene_data moved to Seq::Tracks::GeneTrack::Build

#Should not extend Seq::Tracks::Build, because $self->name will be overwritten
#This is purely a helper class, to prepare the requisite data
#The consuming class will write what it needs to write

#We could of course change this design, I can see advantage of better encapsulation
package Seq::Tracks::Region::Gene::TX;

our $VERSION = '0.001';

# ABSTRACT: Class for creating particular sites for a given gene / transcript
# VERSION

=head1 DESCRIPTION

  @class B<Seq::Gene>
  #TODO: Check description

  @example

Used in:
=for :list
* Seq::Build::GeneTrack
    Which is used in Seq::Build
* Seq::Build::TxTrack
    Which is used in Seq::Build

Extended by: None

=cut

use Moose 2;

use Carp qw/ confess /;
use namespace::autoclean;
use DDP;
use List::Util qw/reduce/;
use POSIX;

use Seq::Tracks::Reference;
#this doesn't really seem to add anything
#because we moved codon_2_aa out to Seq::Site::Gene::Definition
#ref_codon_seq , and ref_aa_residue just wraps that
#use Seq::Site::Gene;

#the definition files hold the common
with 'Seq::Role::Message', 'Seq::Tracks::Region::Gene::Site',
'Seq::Tracks::Region::Gene::Definition';

# has features of a gene and will run through the sequence
# build features will be implmented in Seq::Build::Gene that can build GeneSite
# objects
# would be useful to extend to have capcity to build peptides

#this *feels* a bit like a hack, but I can't think of a more elegant
#way than this; so I think it's just discomfort with essentially declaring
#something twice, once in a separate package that encapsulates the names
#in any case, I think this was smart to use (not my code)
state $spliceSiteLength = 6;
state $fivePrimeBase = '2';
state $threePrimeBase = '1';
state $nonCodingBase = '0';

#added this to avoid having to go through flanking sites
#because I saw flanking sites as only being used to generate the 
#site type, which was alrady generated by a separate block of code
  #(_buildTranscriptAnnotations)
state $spliceAcSite = '3';
state $spliceDonSite = '4';

#used in writing peptide, which isn't done now,
#and also to get the codon sequence
has transcriptSequence => (
  is      => 'ro',
  isa     => 'Str',
  init_arg => undef,
  default => '',
  lazy    => 1,
  traits  => ['String'],
  writer  => '_writeTranscriptSequence',
  handles => { getTranscriptBases => 'substr', },
);

# uses transcriptAnnotations to figure out if anything went wrong
has transcriptErrors => (
  is      => 'rw',
  isa     => 'ArrayRef',
  lazy    => 1,
  init_arg => undef,
  builder => '_buildTranscriptErrors',
  traits  => ['Array'],
  handles => {
    noTranscriptErrors   => 'is_empty',
    allTranscriptErrors => 'elements',
  },
);

# used in making the transcriptAnnotations as well as codon details
# has transcriptPositions => (
#   is      => 'ro',
#   init_arg => undef,
#   isa     => 'ArrayRef[Int]',
#   traits  => ['Array'],
#   handles => {
#     getTranscriptPos => 'get',
#     allTranscriptPos => 'elements',
#   },
#   lazy    => 1,
#   default => sub{ [] },
#   writer  => '_writeTranscriptPositions',
# );

# used in building the codon details
# this could likely be optimized out; right now it stores some, but not all
# of the final annotations, made during the building of the transcript sequence
has txAnnotation => (
  is      => 'ro',
  isa     => 'Str',
  traits  => ['String'],
  lazy    => 1,
  init_arg => undef,
  default => '',
  writer  => '_writeTranscriptAnnotation',
  handles => { 
    getTranscriptAnnotation => 'substr', 
  },
);

#maps a position in the annotation sequence string to a reference position
has txAnnotationPositionMap => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  init_arg => undef,
  default => sub { {} },
  writer => '_writeTxAnnotionPositionMap',
  handles => {
    getTranscriptPosition => 'get',
  }
)

# stores all of our individual sites
# these can be used by the consumer to write per-reference-position
# codon information
has transcriptSites => (
  is      => 'rw',
  isa     => 'HashRef[HashRef]',
  default => sub { [] },
  traits  => ['Hash'],
  handles => {
    allTranscriptSitePos => 'keys',
    getTranscriptSite => 'get',
  },
  lazy => 1,
  init_arg => undef,
  builder => '_buildTranscriptSites',
);

#trying to move away from Seq::Site::Gene;
#not certain if needed yet; I think to get data back
#all that is needed is to deserialize and match on desired features
#which in the case of gene, is really everything written into the sparse
#track
#So instead of this transcriptSites object
#I think it better to just write everything we need into the db
#for each position; in which case, this will never need to be called
has transcriptSites => (
  is      => 'ro',
  isa     => 'ArrayRef[HashRef]',
  traits  => ['Array'],
  handles => {
    allTranscriptSites => 'elements',
  },
  lazy => 1,
  default => sub { [] },
  writer => '_writeTranscriptSites',
);

#not using seq::site::gene
# has flankingSites => (
#   is      => 'rw',
#   isa     => 'ArrayRef[HashRef]',
#   default => sub { [] },
#   traits  => ['Array'],
#   init_arg => undef,
#   handles => {
#     allFlankingSites => 'elements',
#     addFlankingSites => 'push',
#   },
# );

# not writing peptides anymore, can add back
# has peptide => (
#   is      => 'rw',
#   isa     => 'Str',
#   default => q{},
#   traits  => ['String'],
#   handles => {
#     lenAminoResidue => 'length',
#     addAminoResidue => 'append',
#   },
# );

# I think this is confusing
# my impression is that it provides duplicate information
# but encapsulated. not certain it's necessary
# has alt_names => (
#   is      => 'rw',
#   isa     => 'HashRef',
#   traits  => ['Hash'],
#   default => sub { {} },
#   handles => {
#     all_alt_names => 'kv',
#     get_alt_names => 'get',
#     set_alt_names => 'set',
#   },
# );

sub getTxInfo {
  my $self = shift;

  return {
    transcriptSequence => $self->transcriptSequence,
    transcriptPositions => $self->transcriptPositions,
    transcriptAnnotation => $self->transcriptAnnotation,
    transcriptErrors => $self->transcriptErrors,
    peptide => $self->peptide,
  }
}

sub BUILD {
  my $self = shift;

  #seeds transcriptSequence and transcriptPositions
  $self->_buildTranscript; 
  #We no longer strictly need to set 'abs_pos' for each exon_end
  #We *could* subtract $based from each position, but skipping for now because
  #it seems unlikely that we'll start accepting 1-based gene tracks
  #maybe if UCSC loses it's dominance

  # the by-product of _build_transcript_sites is to build the peptide
  $self->_build_transcript_sites;

  #I assume flanking sites are used for nearest gene
  #$self->_build_flanking_sites;
}

# give the sequence with respect to the direction of transcription / coding
# at the same time, creates an array of the positions to which that transcript
# belongs, and assigns what we call that thing

#this combines _build_transcript_db, _build_flanking_sites, _build_transcript_abs_position
#since those mostly do the exact same thing, except in what they store
#and flanking sites is really adding data to the transcript_annotation

#note that we no longer have absolute positions, so we don't call them absolute
#(because we're storing position by chr in the kv database)
sub _buildTranscript {
  my $self        = shift;
  my @exonStarts = $self->allExonStarts;
  my @exonEnds   = $self->allExonEnds;
  my $codingStart = $self->cdsStart;
  my $codingEnd = $self->cdsEnd;

  my $seq;

  my $refTrack = Seq::Tracks::Reference->new();
  #in scalar, as in less than, @array gives length
  my @exonPositions;
  for ( my $i = 0; $i < @exonStarts; $i++ ) {
    if ( $exonStarts[$i] >= $exonEnds[$i] ) {
      $self->tee_logger('error', "exon start $exonStarts[$i] >= end $exonEnds[$i]");
      die;
    }

    #exonEnds is closed, so the actual exonEnd is - 1
    #exonStarts are open
    #http://genomewiki.ucsc.edu/index.php/Coordinate_Transforms
    #perl range is always closed
    #https://ideone.com/AKKpfC
    my $exonPosHref = [ $exonStarts[$i] .. $exonEnds[$i] - 1 ];

    #limitation of the below API; we need to copy $posHref
    #thankfully, we needed to do this anyway.
    #we push them in order, so the first position in the 
    push @exonPositions, @$exonPosHref;

    #dbGet modifies $posRange in place, accumulates the values in order
    #we accumulate values into $posRange, 1 tells us not to sort $posRange first
    #but for now, until API is settled let's not rely on reference mutation
    my $dAref = $self->dbGet($self->chrom, $exonPosHref, 1); 

    $seq .= reduce { $a . $refTrack->get($b) } @$dAref;
    # The above replaces this from _build_transcript_db; 
    # note that we still respect half-closed exonEnds range
    # for ( my $i = 0; $i < @exon_starts; $i++ ) { #half closed
    #   my $exon;
    #   for ( my $abs_pos = $exon_starts[$i]; $abs_pos < $exon_ends[$i]; $abs_pos++ ) {
    #     $exon .= $self->get_base( $abs_pos, 1 );
    #   }
    #   # say join ("\t", $exon_starts[$i], $exon_ends[$i], $exon);
    #   $seq .= $exon;
    # }
  }

  if ( $self->strand eq "-" ) {
    #reverse the sequence, just as in _build_transcript_db
    $seq = reverse $seq;
    # get the complement, just as in _build_transcript_db
    $seq =~ tr/ACGT/TGCA/;
    #reverse the positions, just as done in _build_transcript_abs_position
    @exonPositions = reverse @exonPositions;
  }

  #write these things
  #I don't htink the transcript positions are needed
  #we should map instead to annotation positions
  #$self->_writeTranscriptPositions( \@exonPositions );
  $self->_writeTranscriptSequence( $seq );

  #now build the annotation, which uses the transcript string
  #we can re-use the same string, since that is no longer needed here
  #pass by copy, but avoid more database calls
  self->_buildTranscriptAnnotation( $seq, \@exonPositions );
}

sub _buildTranscriptAnnotation {
  my ($self, $seq, $exonPositionsHref) = @_

  my @exonStarts = $self->allExonStarts;
  my @exonEnds   = $self->allExonEnds;
  my $codingStart = $self->cdsStart;
  my $codingEnd = $self->cdsEnd;

  my $posStrand = $self->strand eq '+';
  #https://ideone.com/B3ygW6
  #is this a bug? isn't cdsEnd open, so shouldn't it be cdsStart == cdsEnd - 1
  #nope: http://genome.soe.ucsc.narkive.com/NHHMnfwF/cdsstart-cdsend-definition
  my $nonCoding = $self->cdsStart == $self->cdsEnd;
  
  #Map locations to annotations
  #I find it easier to work with hashes in this instances
  my %positionMap;
  my $posIdx;
  #posIdx corresponds to the place in the transcript sequence that we've stored
  #, whereas the $exonPos indicates the position in the chromosome.
  for my $exonPos (@exonPositionsHref) {
    $positionMap{$exonPos} = $posIdx;
    $posIdx++;
  }

  #First generated the non-coding, 5'UTR, 3'UTR annotations
  for (my $i = 0; $i < @exonStarts; $i++) {
    BETWEEN_LOOP: for ( my $exonPos = $exonStarts[$i]; $pos < $exonEnds[$i]; $pos++ ) {
      #where are we in the $seq that we've recorded
      #since that is a 0 indexed string that we've built, whose indices don't tell
      #us anything about where that is in the genome
      #a consequence of not rebuilding the transcript here.
      my $posInSequence = $positionMap{$exonPos};

      if(nonCoding) {
        #replace that base in the sequence with our non-coding code
        #Note that this block will replace all bases with a $nonCodingBase
        #substr can be used as a left hand operator
        #https://ideone.com/RVDypI
        #the last term is length, so it's appropriate to not subtract one from
        #end - start, despite end being half closed
        #say end is 3 and start is 2, that's a single base; 3-2 = 1 and the 
        #substring would replace only the starting base
        #https://ideone.com/RVDypI
        my $length = $exonEnds[$i] - $exonStarts[$i];
        

        substr( $seq, $posInSequence, $length ) = $nonCodingBase x $length;
        last BETWEEN_LOOP;
      }

      #TODO this may be a subtle bug, I think it shuold be $pos <= $codingEnd
      #checking with Thomas
      #was <, for now <=
      if( $exonPos <= $codingEnd ) {
        if( $exonPos >= $codingStart ) {
          #not 5'UTR,3'UTR, or non-coding
          #we've alraedy gotten the ref base at this position in $seq
          #so skip this pos
          next; 
        }
        #if we're before cds start, but in an exon we must be in the 5' UTR
        #http://www.perlmonks.org/?node_id=889729
        substr($seq, $posInSequence, 1) = $fivePrimeBase;
        next;
      }
      #if we're after cds end, but in an exon we must be in the 3' UTR
      #since codingEnd is open, >= really means > codingEnd - 1
      #so we must be in the 3' UTR, if we're in the transcript
      substr($seq, $posInSequence, 1) = $threePrimeBase;
    }

    # Annotate splice donor/acceptor bp
    #  - i.e., bp within 6 bp of exon start / stop
    #  - what we want to capture is the bp that are within 6 bp of the start or end of
    #    an exon start/stop; whether this is only within the bounds of coding exons does
    #    not particularly matter to me
    #
    # From the gDNA:
    #
    #        EStart    CStart          EEnd       EStart    EEnd      EStart   CEnd      EEnd
    #        +-----------+---------------+-----------+--------+---------+--------+---------+
    #  Exons  111111111111111111111111111             22222222           333333333333333333
    #  Code               *******************************************************
    #  APR                                        ###                ###
    #  DNR                                %%%                  %%%
    #
    #The only deviation here from Thomas' flanking_sites code
    #is that we don't check for the strand here, because we're already
    #flipped around the coding start and coding end positions above
    #TODO: double check this works as expected

    #TODO: check that there isn't a subtle bug, in that we should be checking
    #exonStarts[$i] -n >= $codingStart and <= $codingEnd
    for ( my $n = 1; $n <= $spliceSiteLength; $n++ ) {
      my $exonPos = $exonStarts[$i] - $n;
      if ( $exonPos > $codingStart && $exonPos < $codingEnd ) {
        #get the position in the sequence string
        #note that we may not actually have this position, because it's outside
        #in fact, I would expect it would never include the exon
        my $posInSequence = $positionMap{$exonPos};

        if(!$posInSequence) {
          $posInSequence = 
        } else {
          $self->tee_logger('debug', 'Splice site in exon sequence');
        }
        
        #inserting value in between strings
        #https://ideone.com/LlAbeE
        substr($seq, $posInSequence, 1) = 
          substr($seq, $posInSequence, 1) . $posStrand ? $spliceAcSite : $spliceDonSite;
        next;
      }

      #inserting into a string https://ideone.com/LlAbeE
      $pos = $exonStarts[$i] + $n - 1;
      if ( $pos > $codingStart && $pos < $codingEnd ) {
        #get the position in the sequence string
        my $posInSequence = $positionMap{$pos};
        #because exonEnds are open (not including the specified end) subtract 1
        substr($seq, $posInSequence, 1) = $posStrand ? $spliceDonSite : $spliceAcSite;
        next;
      }
    }

    #although maybe awkward, we generate the coding annotation later
    #we could always change that, put it here
  }

  #once we've processed all sites, we need to flip around the 5' and 3' UTR
  #designators if we're on neg strand
  if ( $negStrand ) {
    # flip 5' and 3' UTR distinction
    # if this is negative strand, we already have the reverse compliment $seq
    # from _buildTranscript
    $seq =~ tr/53/35/;
  }

  $self->_writeTranscriptAnnotation($seq);
}

#The only goal here now is to store errors in an array
sub _buildTranscriptErrors {
  my $self = shift;
  state $atgRe = qr/\AATG/; #starts with ATG
  state $stopCodonRe = qr/(TAA|TAG|TGA)\Z/; #ends with a stop codon

  my @errors;
  # check coding sequence is
  #   1. divisible by 3
  #   2. starts with ATG
  #   3. Ends with stop codon

  # check coding sequence
  my $codingSeq = $self->transcriptAnnotation;
  #remove our annotations
  #Need to actually say to match 1 or more (or 0 or more)
  #wrong: https://ideone.com/CRZsKf
  #right: https://ideone.com/5ghTbk
  $codingSeq =~ s/[$fivePrimeBase]*//xm;
  $codingSeq =~ s/[$threePrimeBase]*//xm;
  $codingSeq =~ s/[$spliceAcSite]*//xm;
  $codingSeq =~ s/[$spliceDonSite]*//xm;

  if ( $self->cdsStart == $self->cdsEnd ) {
    #it's a non-coding site, so it has no sequence information stored at all
    return;
  } else {
    if ( length $codingSeq % 3 ) {
      push @errors, 'coding sequence not divisible by 3';
    }

    #Since at this point we've removed our 5' and 3' base annotations,
    #our regex doesn't need to account for those sites (hence removal of 
    #[$fivePrimeBase]* and [$threePrimeBase]* )
    # check begins with ATG
    if ( $self->transcriptAnnotation !~ m/$atgRe/ ) {
      push @errors, 'transcript does not begin with ATG';
    }

    # check stop codon
    if ( $self->transcriptAnnotation !~ m/$stopCodonRe/ ) {
      push @errors, 'transcript does not end with stop codon';
    }
  }
  
  return \@errors;
}



=method @constructor _build_transcript_sites

  Fetches an annotation using Seq::Site::Gene.
  Populates the @property {Str} peptide.
  Populates the @property {ArrayRef<Seq::Site::Gene>} transcript_sites

@requires
=for :list
* @method {ArrayRef<Str>} $self->all_exon_starts
* @method {ArrayRef<Str>} $self->all_exon_ends
* @property {Int} $self->coding_start
* @property {Int} $self->coding_end
* @property {Str} $self->transcript_id
* @property {Str} $self->chr
* @property {Str} $self->strand
* @property {ArrayRef<Str>} $self->all_transcript_errors
* @method {ArrayRef<Str>} $self->all_transcript_abs_position
* @method {Str} $self->get_str_transcript_annotation
* @method {int} $self->get_transcript_abs_position
* @property {HashRef} $self->alt_names
* @method {Str} $self->get_base_transcript_seq
* @method {ArrayRef} $self->transcript_error
* @class Seq::Site::Gene
* @method $self->add_aa_residue (setter, Str append alias)
* @method $self->addTranscriptSite (setter, Array push alias)

@returns void

=cut
#was build_transcript_sites
sub _buildTranscriptSites {
  my $self              = shift;

  my @exonStarts       = $self->allExonStarts;
  my @exonEnds         = $self->allExonEnds;
  
  my $codingBaseCount = 0;
  #my $lastCodonNumber = 0;

  if ( $self->noTranscriptErrors ) {
    $self->log('info', join( " ", $self->name, $self->chrom, $self->strand ) );
  } else {
    $self->log('warn', join( " ", $self->name, $self->chrom, $self->strand, 
      $self->allTranscriptErrors ) );
  }

  #( $self->allTranscriptPos ) is another way to say @{ $self->allTranscriptPos }
  for ( my $i = 0; $i < ( $self->allTranscriptPos ); $i++ ) {
    my (
      $annotation_type, $codon_seq, $codon_number,
      $codon_position,  %gene_site, $siteAnnotation,
      $siteType, $referenceCodonSeq
    );

    $siteAnnotation = $self->getTranscriptAnnotation( $i, 1 );

    #maybe this should go in prepareCodonDetails (the -9 specific.)
    my ($codonNumber, $codonPosition) = (-9, -9);
    
    # is site coding
    if ( $siteAnnotation =~ m/[ACGT]/ ) {
      $codonNumber   = 1 + POSIX::floor( ( $codingBaseCount / 3 ) );
      
      $codonPosition = $codingBaseCount % 3;

      my $codonStart = $i - $codonPosition;
      #my $codonEnd   = $codonStart + 2;
      #say "codon_start: $codon_start, codon_end: $codon_end, i = $i, coding_bp = $coding_base_count";
      #for ( my $j = $codonStart; $j <= $codonEnd; $j++ ) {
        #TODO: account for messed up transcripts that are truncated
        #$referenceCodonSeq .= $self->getTranscriptBases( $j, 1 );
      }
      #I think this is more efficient, also clearer (to me) because the 3 
      #is explicit, rather than implict through the +2 and for loop and 0 offset substr
      #https://ideone.com/lDRULc
      $referenceCodonSeq = $self->getTranscriptBases( $codonStart, 3 );
      $codingBaseCount++;

      #since it's a coding site, call it that
      $siteType = $self->codingSiteType;

      #and if not, call it something else
    } elsif ( $siteAnnotation eq $fivePrimeBase ) {
      $siteType = $self->fivePrimeSiteType;
    } elsif ( $siteAnnotation eq $threePrimeBase ) {
      $siteType = $self->threePrimeSiteType;
    } elsif ( $siteAnnotation eq $nonCodingBase ) {
      $siteType = $self->ncRNAsiteType;
    } elsif ( $siteAnnotation eq $spliceAcSite ) {
      $siteType = $self->spliceAcSiteType;
    } elsif ( $siteAnnotation eq $spliceDoSite ) {
      $siteType = $self->spliceDoSiteType;
    } else {
      $self->tee_logger('error', "unknown site code $siteAnnotation");
      die 'unknown site code $siteAnnotation';
    }

    #Now store the site details
    #stores the codon information as binary
    #this was "$self->add_transcript_site($site)"
    my $site = $self->prepareCodonDetails($siteType, $codonNumber,
      $codonPosition, $referenceCodonSeq);
    
    #this transcript sites are keyed on reference position
    #this is similar to what was done with Seq::Site::Gene before
    $self->transcriptSites->{ $self->getTranscriptPos($i) } = $site;

    # no longer doing this, spoke with Dave
    # can re-add once rest is up if needed
    # # build peptide
    # if ( $codonNumber ) {
    #   if ( $lastCodonNumber != $codonNumber ) {
    #     $self->addAminoResidue( $self->codon2aa($referenceCodonSeq) );
    #   } else {
    #     say "site obj: ";
    #     p $site;
    #   }
    # }

    #$lastCodonNumber = $codonNumber;
  }
}

=method @constructor _build_flanking_sites

  Annotate splice donor/acceptor bp
   - i.e., bp within 6 bp of exon start / stop
   - what we want to capture is the bp that are within 6 bp of the start or end of
     an exon start/stop; whether this is only within the bounds of coding exons does
     not particularly matter to me

  From the gDNA:

         EStart    CStart          EEnd       EStart    EEnd      EStart   CEnd      EEnd
         +-----------+---------------+-----------+--------+---------+--------+---------+
   Exons  111111111111111111111111111             22222222           333333333333333333
   Code               *******************************************************
   APR                                        ###                ###
   DNR                                %%%                  %%%


@requires
=for :list
* @method {ArrayRef<Str>} $self->all_exon_starts
* @method {ArrayRef<Str>} $self->all_exon_ends
* @property {Int} $self->coding_start
* @property {Int} $self->coding_end
* @variable @private {Int} $splice_site_length
* @property {HashRef} $self->alt_names
* @property {Str} $self->strand
* @property {Str} $self->transcript_id
* @method {ArrayRef} $self->transcript_error
* @class Seq::Site::Gene
* @method $self->add_flanking_sites (setter, alias to push)
* @method {Str} $self->get_base (getter, for @property genome_track)

@returns void
=cut

# sub _build_flanking_sites {

#   # Annotate splice donor/acceptor bp
#   #  - i.e., bp within 6 bp of exon start / stop
#   #  - what we want to capture is the bp that are within 6 bp of the start or end of
#   #    an exon start/stop; whether this is only within the bounds of coding exons does
#   #    not particularly matter to me
#   #
#   # From the gDNA:
#   #
#   #        EStart    CStart          EEnd       EStart    EEnd      EStart   CEnd      EEnd
#   #        +-----------+---------------+-----------+--------+---------+--------+---------+
#   #  Exons  111111111111111111111111111             22222222           333333333333333333
#   #  Code               *******************************************************
#   #  APR                                        ###                ###
#   #  DNR                                %%%                  %%%
#   #

#   my $self         = shift;
#   my @exon_starts  = $self->all_exon_starts;
#   my @exon_ends    = $self->all_exon_ends;
#   my $coding_start = $self->coding_start;
#   my $coding_end   = $self->coding_end;
#   my (@sites);

#   for ( my $i = 0; $i < @exon_starts; $i++ ) {
#     for ( my $n = 1; $n <= $splice_site_length; $n++ ) {

#       # flanking sites at start of exon
#       if ( $exon_starts[$i] - $n > $coding_start
#         && $exon_starts[$i] - $n < $coding_end )
#       {
#         my %gene_site;
#         $gene_site{abs_pos}   = $exon_starts[$i] - $n;
#         $gene_site{alt_names} = $self->alt_names;
#         $gene_site{site_type} =
#           ( $self->strand eq "+" ) ? 'Splice Acceptor' : 'Splice Donor';
#         $gene_site{ref_base}      = $self->get_base( $gene_site{abs_pos}, 1 );
#         $gene_site{error_code}    = $self->transcript_error;
#         $gene_site{transcript_id} = $self->transcript_id;
#         $gene_site{strand}        = $self->strand;
#         $self->add_flanking_sites( Seq::Site::Gene->new( \%gene_site ) );
#       }

#       # flanking sites at end of exon
#       if ( $exon_ends[$i] + $n - 1 > $coding_start
#         && $exon_ends[$i] + $n - 1 < $coding_end )
#       {
#         my %gene_site;
#         $gene_site{abs_pos}   = $exon_ends[$i] + $n - 1;
#         $gene_site{alt_names} = $self->alt_names;
#         $gene_site{site_type} =
#           ( $self->strand eq "+" ) ? 'Splice Donor' : 'Splice Acceptor';
#         $gene_site{ref_base}      = $self->get_base( $gene_site{abs_pos}, 1 );
#         $gene_site{error_code}    = $self->transcript_error;
#         $gene_site{transcript_id} = $self->transcript_id;
#         $gene_site{strand}        = $self->strand;
#         $self->add_flanking_sites( Seq::Site::Gene->new( \%gene_site ) );
#       }
#     }
#   }
# }

__PACKAGE__->meta->make_immutable;

1;
