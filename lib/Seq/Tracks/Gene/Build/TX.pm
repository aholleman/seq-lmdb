use 5.10.0;
use strict;
use warnings;

# ABSTRACT: Creates a hash reference of sites with information in them
=head1 DESCRIPTION
  # A consuming build class stores this info at some key in the main database
=cut

#TODO: Thomas. I may have misunderstood your intentions here. I spoke with
#Dave, and we decided, I believe, not to write peptides, because those 
#were already reconstructed at annotation time (codon2AA)
#If I made significant mistakes here, 1000 apologies. I did my best
#to follow your code base, and the changes made were done for a few reasons:
#1) Make it easier for me to understand
#2) Make it clearer to future developers exactly what this class is responsible for
#3) Reduce the amount of code to the minimum needed to output a transcriptSite
#4) Related to #3, don't use moose attributes unless need $self or exposed as public API

package Seq::Tracks::Gene::Build::TX;

our $VERSION = '0.001';

use Moose 2;

use namespace::autoclean;
use List::Util qw/reduce/;

use Seq::Tracks::Reference;
use Seq::Tracks::Gene::Site;

with 'Seq::Role::Message',
#all of the site types we can use
'Seq::Site::Definition';

# has features of a gene and will run through the sequence
# build features will be implmented in Seq::Build::Gene that can build GeneSite
# objects
# would be useful to extend to have capcity to build peptides

# stores all of our individual sites
# these can be used by the consumer to write per-reference-position
# codon information
# The only public variable other than transcriptErrors, which we may discard
has transcriptSites => (
  is      => 'ro',
  isa     => 'HashRef[HashRef]',
  traits  => ['Hash'],
  handles => {
    allTranscriptSitePos => 'keys',
    getTranscriptSite => 'get',
  },
  lazy => 1,
  default => sub { {} },
  init_arg => undef,
);

# Also public (for now)
# uses transcriptAnnotations to figure out if anything went wrong
has transcriptErrors => (
  is      => 'rw',
  isa     => 'ArrayRef',
  writer => '_writeTranscriptErrors',
  traits  => ['Array'],
  handles => {
    noTranscriptErrors   => 'is_empty',
    allTranscriptErrors => 'elements',
  },
  lazy    => 1,
  default => sub { [] },
  init_arg => undef,
);

###private
has _geneSite => (
  is => 'ro',
  isa => 'Seq::Tracks::Gene::Site',
  handles => {    
    packCodon => 'packCodon',
  },
  init_arg => undef,
  default => sub { Seq::Tracks::Gene::Site->new() },
);

###All required arguments

has exonStarts => (
  is => 'ro',
  isa => 'ArrayRef',
  handles => {
    allExonStart => 'elements',
  },
  required => 1,
);

has exonEnds => (
  is => 'ro',
  isa => 'ArrayRef',
  handles => {
    allExonEnds=> 'elements',
  },
  required => 1,
);

has cdsStart => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has cdsEnd => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has strand => (
  is => 'ro',
  isa => 'StrandType',
  required => 1,
);
#how many bases away from exon bound we will call spliceAc or spliceDon site
state $spliceSiteLength = 6;

#coerce our exon starts and ends into an array
around BUILDARGS => sub {
  my ($class, $orig, $href) = @_;

  $href->{exonStarts} = split(',', $href->{exonStarts} );
  $href->{exonEnds} = split(',', $href->{exonEnds} );

  $class->$orig($href);
};
#Each functino in build is responsible for 1 thing
#and therefore can be tested separately
#using Go-like error reporting
sub BUILD {
  my $self = shift;

  #seeds transcriptSequence and transcriptPositions
  my ($seq, $seqPosMapAref, $errorsAref) = $self->_buildTranscript();

  #if errors
  if(@$errorsAref) {
    $self->log('error', $errorsAref); #will die for us.
  }

  my $txAnnotationHref = self->_buildTranscriptAnnotation();
  #We no longer strictly need to set 'abs_pos' for each exon_end
  #We *could* subtract $based from each position, but skipping for now because
  #it seems unlikely that we'll start accepting 1-based gene tracks
  #maybe if UCSC loses it's dominance

  # transcriptSites holds all of our site annotations
  $self->_buildTranscriptSites($seq, $seqPosMapAref, $txAnnotationHref);

  #this is now handled as part of the buildTranscript process
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

  my (@sequencePositions, $txSequence);

  my $refTrack = Seq::Tracks::Reference->new();
  #in scalar, as in less than, @array gives length
  for ( my $i = 0; $i < @exonStarts; $i++ ) {
    if ( $exonStarts[$i] >= $exonEnds[$i] ) {
      $self->log('fatal', "exon start $exonStarts[$i] >= end $exonEnds[$i]");
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
    #https://ideone.com/wq0YJO (dereferencing not strictly necessary, but I think clearer)
    push @sequencePositions, @$exonPosHref;

    #dbGet modifies $posRange in place, accumulates the values in order
    #we accumulate values into $posRange, 1 tells us not to sort $posRange first
    #but for now, until API is settled let's not rely on reference mutation
    my $dAref = $self->dbGet($self->chrom, $exonPosHref, 1); 

    #https://ideone.com/1sJC69
    $txSequence .= reduce { $a . $refTrack->get($b) } @$dAref;
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

  my $errorsAref = $self->_buildTranscriptErrors($txSequence);

  if ( $self->strand eq "-" ) {
    #reverse the sequence, just as in _build_transcript_db
    $txSequence = reverse $txSequence;
    # get the complement, just as in _build_transcript_db
    $txSequence =~ tr/ACGT/TGCA/;
    #reverse the positions, just as done in _build_transcript_abs_position
    @sequencePositions = reverse @sequencePositions;
  }

  return ($txSequence, \@sequencePositions, $errorsAref);
}

sub _buildTranscriptAnnotation {
  my $self = shift;

  my @exonStarts = $self->allExonStarts;
  my @exonEnds   = $self->allExonEnds;
  my $codingStart = $self->cdsStart;
  my $codingEnd = $self->cdsEnd;

  my $posStrand = $self->strand eq '+';
  #https://ideone.com/B3ygW6
  #is this a bug? isn't cdsEnd open, so shouldn't it be cdsStart == cdsEnd - 1
  #nope: http://genome.soe.ucsc.narkive.com/NHHMnfwF/cdsstart-cdsend-definition
  my $nonCoding = $self->cdsStart == $self->cdsEnd;

  my $txAnnotationHref;
  #First generated the non-coding, 5'UTR, 3'UTR annotations
  for (my $i = 0; $i < @exonStarts; $i++) {
    RANGE_LOOP: for ( my $exonPos = $exonStarts[$i]; $exonPos < $exonEnds[$i]; $exonPos++ ) {
      if($nonCoding) {
        $txAnnotationHref->{$exonPos} = $self->ncRNAsiteType;
        next RANGE_LOOP;
      }

      #TODO this may be a subtle bug, I think it shuold be $pos <= $codingEnd
      #checking with Thomas
      if( $exonPos < $codingEnd ) {
        if( $exonPos >= $codingStart ) {
          #not 5'UTR,3'UTR, or non-coding
          #we've alraedy gotten the ref base at this position in $seq
          #so skip this pos
          next; 
        }
        #if we're before cds start, but in an exon we must be in the 5' UTR
        $txAnnotationHref->{$exonPos} = $posStrand ? $self->fivePrimeSiteType 
          : $self->threePrimeSiteType;
        next;
      }
      #if we're after cds end, but in an exon we must be in the 3' UTR
      $txAnnotationHref->{$exonPos} = $posStrand ? $self->threePrimeSiteType 
        : $self->fivePrimeSiteType;
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

    #TODO: should we check if start + n is past end? or >= end - $n
    for ( my $n = 1; $n <= $spliceSiteLength; $n++ ) {
      my $exonPos = $exonStarts[$i] - $n;
      if ( $exonPos > $codingStart && $exonPos < $codingEnd ) {
        $txAnnotationHref->{$exonPos} = $posStrand ? $self->spliceAcSiteType : 
          $self->spliceDonSiteType;
        next;
      }

      #inserting into a string https://ideone.com/LlAbeE
      #TODO: why aren't we checking <= $codingEnd? I thought codingEnd was closed range
      $exonPos = $exonStarts[$i] + $n - 1;
      if ( $exonPos > $codingStart && $exonPos < $codingEnd ) {
        $txAnnotationHref->{$exonPos} = $posStrand ? 
          $self->spliceDonSiteType : $self->spliceAcSiteType;
      }
    }
  }

  return $txAnnotationHref;
}

#TODO: double check that this works properly
#TODO: think about whether we want to pack anything if no info
#the problem with not packing something is we won't know how to unpack it apriori
sub _buildTranscriptSites {
  my ($self, $txSequence, $seqPosMapAref, $txAnnotationHref) = @_;
  my @exonStarts       = $self->allExonStarts;
  my @exonEnds         = $self->allExonEnds;

  # we build up our site annotations in 2 steps
  # 1st record everything as if it were a coding sequence
  # then we overwrite those entries if there were other annotations associated
  # advantage is we can keep 3-mer info for those annotated sites
  # and don't need to modify the $txSequence string in _buildTranscrtipAnnotation
  # which may be (for me) a bit easier to reason about
  my %tempTXsites;

  #First add the annotations; note that if for some reason a codon overlaps
  for my $chrPos (keys %$txAnnotationHref) {
    my $siteType =  $txAnnotationHref->{$chrPos};

    #storing strand for now, could remove it later if we decided to 
    #just get it from the region database entry for the transcript
    $tempTXsites{$chrPos} = [$siteType, $self->strand, undef, undef, undef];
  }

  my $codingBaseCount = 0;
  #Then, make all of the codons in locations that aren't in the $tempTXsites

  #Example (informal test): #https://ideone.com/a9NYhb
  CODING_LOOP: for (my $i = 0; $i < length($txSequence); $i++ ) {
    #get the genomic position
    my $chrPos = $seqPosMapAref->{$i};

    #not that we could store codons for annotated sites (which are everything 
    # but coding sites)
    # however not doing this here to keep logic compat with old codebase
    # note that this also means that as before, codons are only counted for
    # non-UTR, non-splice site, non-noncoding bases, which generally makes sense
    # but could seem problematic if we allow multiple annotations at one site
    # (say Coding and "Uber deleterious")
    # or if we make a mistake with our annotation logic and over-write
    # a true coding site. For this last reason I'm hesitant to use this logic
    # but cannot see a better way
    if(exists $tempTXsites{$chrPos} ) {
      next CODING_LOOP;
    }

    my ($siteType, $codonNumber, $codonPosition, $codonSeq);
    
    # check if site is coding; all should be at this point since we're
    # just checking the reference string built from exon coord (in _buildTranscript)
    # the regex is purely for safety in case weirdness in source file that 
    # wasn't caught earlier (say if this function used outside this class)
    
    if ( substr($txSequence, $i, 1) =~ m/[ACGT]/ ) {
      #the codon number ; POSIX::floor safer than casting int for rounding
      #but we just want to truncate; http://perldoc.perl.org/functions/int.html
      $codonNumber   = 1 + int( $codingBaseCount / 3 );
      
      $codonPosition = $codingBaseCount % 3;

      my $codonStart = $i - $codonPosition;
      #my $codonEnd   = $codonStart + 2;
      #say "codon_start: $codon_start, codon_end: $codon_end, i = $i, coding_bp = $coding_base_count";
      #for ( my $j = $codonStart; $j <= $codonEnd; $j++ ) {
        #TODO: account for messed up transcripts that are truncated
        #$referenceCodonSeq .= $self->getTranscriptBases( $j, 1 );
      #}
      #I think this is more efficient, also clearer (to me) because the 3 
      #is explicit, rather than implict through the +2 and for loop and 0 offset substr
      
      #https://ideone.com/lDRULc
      $codonSeq = substr( $txSequence, $codonStart, 3 );

      $siteType = $self->codingSiteType;

      $tempTXsites{ $chrPos } = [$siteType, $self->strand,
       $codonNumber, $codonPosition, $codonSeq];

      $codingBaseCount++;
      next CODING_LOOP;
    }

    $self->log('warn', substr($txSequence, $i, 1) . "at $chrPos not A|T|C|G");
  }

  #At this point, we have all of the codon information stored.
  #However, some sites won't be coding, and those are in our annotation href

  #Now compact the site details
  for my $chrPos (keys %tempTXsites) {
    #stores the codon information as binary
    #this was "$self->add_transcript_site($site)"
    # passing args in list context 
    # https://ideone.com/By1GDW
    my $site = $self->packCodon( @{$tempTXsites{$chrPos} } );

    #this transcript sites are keyed on reference position
    #this is similar to what was done with Seq::Site::Gene before
    $self->transcriptSites->{ $chrPos } = $site;
  }
}

# check coding sequence is
#   1. divisible by 3
#   2. starts with ATG
#   3. Ends with stop codon
sub _buildTranscriptErrors {
  my $self = shift;
  my $codingSeq =  shift;

  state $atgRe = qr/\AATG/; #starts with ATG
  state $stopCodonRe = qr/(TAA|TAG|TGA)\Z/; #ends with a stop codon

  my @errors;

  if ( $self->cdsStart == $self->cdsEnd ) {
    #it's a non-coding site, so it has no sequence information stored at all
    return;
  }

  if ( length $codingSeq % 3 ) {
    push @errors, 'coding sequence not divisible by 3';
  }

  if ( $codingSeq !~ m/$atgRe/ ) {
    push @errors, 'transcript does not begin with ATG';
  }

  if ( $codingSeq !~ m/$stopCodonRe/ ) {
    push @errors, 'transcript does not end with stop codon';
  }

  return \@errors;
}

__PACKAGE__->meta->make_immutable;

1;
