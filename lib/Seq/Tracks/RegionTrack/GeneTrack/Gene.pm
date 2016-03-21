use 5.10.0;
use strict;
use warnings;

#Breaking this thing down to fit in the new contxt
package Seq::Gene;

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

#this doesn't really seem to add anything
#because we moved codon_2_aa out to Seq::Site::Gene::Definition
#ref_codon_seq , and ref_aa_residue just wraps that
#use Seq::Site::Gene;

with 'Seq::Role::Message','Seq::Site::Definition',
'Seq::Tracks::RegionTrack::GeneTrack::Definition';

# has features of a gene and will run through the sequence
# build features will be implmented in Seq::Build::Gene that can build GeneSite
# objects
# would be useful to extend to have capcity to build peptides

state $splice_site_length = 6;
state $fivePrimeBase = '5';
state $threePrimeBase = '3';
state $nonCodingBase = '0';

has referenceTrack => (
  is       => 'ro',
  init_arg => undef,
  defulat  => sub{ Seq::Tracks::ReferenceTrack->new() },
  handles  => {
    getRefBase => 'get',
  }
);

has chrom        => ( is => 'rw', isa => 'Str', required => 1, );
has strand        => ( is => 'rw', isa => 'Str', required => 1, );
has txStart      => ( is => 'rw', isa => 'Int', required => 1, );
has txEnd        => ( is => 'rw', isa => 'Int', required => 1, );
has cdsStart     => ( is => 'rw', isa => 'Int', required => 1, );
has cdsEnd       => ( is => 'rw', isa => 'Int', required => 1, );

has exonStarts => (
  is       => 'rw',
  isa      => 'ArrayRef[Int]',
  required => 1,
  coerce   => 1,
  traits   => ['Array'],
  handles  => {
    all_exon_starts => 'elements',
    get_exon_starts => 'get',
    set_exon_starts => 'set',
  },
);

has exonEnds => (
  is       => 'rw',
  isa      => 'ArrayRef[Int]',
  required => 1,
  coerce   => 1,
  traits   => ['Array'],
  handles  => {
    all_exon_ends => 'elements',
    get_exon_ends => 'get',
    set_exon_ends => 'set',
  },
);

#transcript_id
has name => ( is => 'rw', isa => 'Str', required => 1, );

# I think this is confusing
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

has transcriptPositions => (
  is      => 'ro',
  init_arg => undef,
  isa     => 'ArrayRef',
  traits  => ['Array'],
  handles => {
    getTranscriptPos => 'get',
    allTranscriptPos => 'elements',
  },
  lazy    => 1,
  default => sub{ [] },
  writer  => '_writeTranscriptPositions',
);

has transcriptAnnotation => (
  is      => 'ro',
  isa     => 'Str',
  traits  => ['String'],
  handles => { getTranscriptAnnotation => 'substr', },
  lazy    => 1,
  default => '',
  writer  => '_writeTranscriptAnnotation',
);

has transcriptErrors => (
  is      => 'rw',
  isa     => 'ArrayRef',
  lazy    => 1,
  builder => '_buildTranscriptErrors',
  traits  => ['Array'],
  handles => {
    noTranscriptErrors   => 'is_empty',
    allTranscriptErrors => 'elements',
  },
);

has peptide => (
  is      => 'rw',
  isa     => 'Str',
  default => q{},
  traits  => ['String'],
  handles => {
    lenAminoResidue => 'length',
    addAminoResidue => 'append',
  },
);

#trying to move away from Seq::Site::Gene;
#not certain if needed yet; I think to get data back
#all that is needed is to deserialize and match on desired features
#which in the case of gene, is really everything written into the sparse
#track
#So instead of this transcriptSites object
#I think it better to just write everything we need into the db
#for each position; in which case, this will never need to be called
# has transcriptSites => (
#   is      => 'ro',
#   isa     => 'ArrayRef[HashRef]',
#   traits  => ['Array'],
#   handles => {
#     allTranscriptSites => 'elements',
#   },
#   lazy => 1,
#   default => sub { [] },
#   writer => '_writeTranscriptSites',
# );

has flanking_sites => (
  is      => 'rw',
  isa     => 'ArrayRef[Seq::Site::Gene]',
  default => sub { [] },
  traits  => ['Array'],
  handles => {
    all_flanking_sites => 'elements',
    add_flanking_sites => 'push',
  },
);

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
  $self->_build_flanking_sites;
}

# give the sequence with respect to the direction of transcription / coding
# at the same time, creates an array of the positions to which that transcript
# belongs, and assigns what we call that thing
sub _buildTranscript {
  my $self        = shift;
  my @exonStarts = $self->allExonStarts;
  my @exonEnds   = $self->allExonEnds;
  my $seq;

  #in scalar, as in less than, @array gives length
  my @positions;
  for ( my $i = 0; $i < @exonStarts; $i++ ) {
    my $exon;

    if ( $exonStarts[$i] >= $exonEnds[$i] ) {
      return $self->log('error', "exon start $exonStarts[$i] >= end $exonEnds[$i]");
    }

    #exonEnds is half-closed range, exonEnds aren't included
    my $posHref = [ $exonStarts[$i] .. $exonEnds[$i] - 1 ];

    #limitation of the below API; we need to copy $posHref
    #thankfully, we needed to do this anyway.
    push @positions, @$posHref;

    #dbGet modifies $posRange in place, accumulates the values in order
    #we accumulate values into $posRange, 1 tells us not to sort $posRange first
    #but for now, until API is settled let's not rely on reference mutation
    my $dAref = $self->dbGet($self->chrom, $posHref, 1); 

    $seq .= reduce { $a . $self->getRefBase($b) } @$dAref;
  }

  if ( $self->strand eq "-" ) {
    # get reverse complement
    $seq = reverse $seq;
    $seq =~ tr/ACGT/TGCA/;

    @positions = reverse @positions;
  }

  $self->_writeTranscriptPositions( \@positions );
  $self->_writeTranscriptSequence( $seq );

  #now build the annotation
  if($self->cdsStart == $self->cdsEnd) {
    $seq = $nonCodingBase x scalar @positions;
  } else {
    my $idx = 0;
    my ($codingStart, $codingEnd);

    if ($self->strand eq "-") {
      $codingStart = $self->cdsEnd;
      $codingEnd = $self->cdsStart;
    } else {
      $codingStart = $self->cdsStart;
      $codingEnd = $self->cdsEnd;
    }

    for (my $i = 0; $i < @positions; $i++) {
      if( $positions[$i] < $codingEnd ) {
        if( $positions[$i] >= $codingStart ) {
          next; #we've alraedy gotten the ref base at this position, above
        }
        #if we're before the coding sequence, but in the transcript
        #we must be in the 5' UTR
        #http://www.perlmonks.org/?node_id=889729
        substr($seq, $i, 1) = $fivePrimeBase;
        next;
      }

      #remember that the start to end range is half closd
      #so if we're >= $codingEnd, we're past the coding region
      #so we must be in the 3' UTR, if we're in the transcript
      substr($seq, $i, 1) = $threePrimeBase;
    }
  }

  $self->_writeTranscriptAnnotation($seq);
}

sub _buildTranscriptErrors {
  my $self = shift;
  state $fivePrime         = qr{\A[$fivePrimeBase]+};
  state $threePrime        = qr{[$threePrimeBase]+\z};
  state $atgRe = qr/\A[$fivePrimeBase]*ATG/;
  state $stopCodonRe = qr/(TAA|TAG|TGA)[$threePrimeBase]*\Z/;

  my @errors;
  # check coding sequence is
  #   1. divisible by 3
  #   2. starts with ATG
  #   3. Ends with stop codon

  # check coding sequence
  my $codingSeq = $self->transcriptAnnotation;
  $codingSeq =~ s/$fivePrime//xm;
  $codingSeq =~ s/$threePrime//xm;

  if ( $self->cdsStart == $self->cdsEnd ) {
    return \@errors;
  } else {
    if ( length $codingSeq % 3 ) {
      push @errors, 'coding sequence not divisible by 3';
    }

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
* @method $self->add_transcript_site (setter, Array push alias)

@returns void

=cut

sub _buildPeptide {
  my $self              = shift;
  my @exonStarts       = $self->allExonStarts;
  my @exonEnds         = $self->allExonEnds;
  
  my $codingBaseCount = 0;
  my $lastCodonNumber = 0;

  state $fivePrime         = qr{\A[$fivePrimeBase]+};
  state $threePrime        = qr{[$threePrimeBase]+\z};

  if ( $self->noTranscriptErrors ) {
    $self->log('info', join( " ", $self->name, $self->chrom, $self->strand ) );
  } else {
    $self->log('warn', join( " ", $self->name, $self->chrom, $self->strand, 
      $self->allTranscriptErrors ) );
  }

  for ( my $i = 0; $i < ( $self->allTranscriptPos ); $i++ ) {
    my (
      $annotation_type, $codon_seq, $codon_number,
      $codon_position,  %gene_site, $siteAnnotation
    );
    my $siteType; 
    $siteAnnotation = $self->getTranscriptAnnotation( $i, 1 );

    my $codonNumber;
    my $reqCodonSeq = '';
    # is site coding
    if ( $siteAnnotation =~ m/[ACGT]/ ) {
      $codonNumber   = 1 + int( ( $codingBaseCount / 3 ) );
      
      my $codonPosition = $codingBaseCount % 3;
      my $codonStart = $i - $codonPosition;
      my $codonEnd   = $codonStart + 2;

      #say "codon_start: $codon_start, codon_end: $codon_end, i = $i, coding_bp = $coding_base_count";
      for ( my $j = $codonStart; $j <= $codonEnd; $j++ ) {
        #TODO: account for messed up transcripts that are truncated
        $reqCodonSeq .= $self->getTranscriptBases( $j, 1 );
      }
      $codingBaseCount++;
    } elsif ( $siteAnnotation eq $fivePrimeBase ) {
      $siteType = $self->fivePrimeSiteType;
    } elsif ( $siteAnnotation eq $threePrimeBase ) {
      $siteType = $self->threePrimeSiteType;
    } elsif ( $siteAnnotation eq $nonCodingBase ) {
      $siteType = $self->ncRNAsiteType;
    } else {
      return $self->log('error', "unknown site code $siteAnnotation");
    }

    ### This is the core:

    # build peptide
    if ( $codonNumber ) {
      if ( $lastCodonNumber != $codonNumber ) {
        $self->addAminoResidue( $self->codon_2_aa($reqCodonSeq) );
      } else {
        say "site obj: " . dump($site);
      }
    }

    $lastCodonNumber = $codonNumber;

    #not yet sure of the need for this
    #it could very well be needed, just haven't gotten far enough yet
    # $self->add_transcript_site($site);
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

sub _build_flanking_sites {

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

  my $self         = shift;
  my @exon_starts  = $self->all_exon_starts;
  my @exon_ends    = $self->all_exon_ends;
  my $coding_start = $self->coding_start;
  my $coding_end   = $self->coding_end;
  my (@sites);

  for ( my $i = 0; $i < @exon_starts; $i++ ) {
    for ( my $n = 1; $n <= $splice_site_length; $n++ ) {

      # flanking sites at start of exon
      if ( $exon_starts[$i] - $n > $coding_start
        && $exon_starts[$i] - $n < $coding_end )
      {
        my %gene_site;
        $gene_site{abs_pos}   = $exon_starts[$i] - $n;
        $gene_site{alt_names} = $self->alt_names;
        $gene_site{site_type} =
          ( $self->strand eq "+" ) ? 'Splice Acceptor' : 'Splice Donor';
        $gene_site{ref_base}      = $self->get_base( $gene_site{abs_pos}, 1 );
        $gene_site{error_code}    = $self->transcript_error;
        $gene_site{transcript_id} = $self->transcript_id;
        $gene_site{strand}        = $self->strand;
        $self->add_flanking_sites( Seq::Site::Gene->new( \%gene_site ) );
      }

      # flanking sites at end of exon
      if ( $exon_ends[$i] + $n - 1 > $coding_start
        && $exon_ends[$i] + $n - 1 < $coding_end )
      {
        my %gene_site;
        $gene_site{abs_pos}   = $exon_ends[$i] + $n - 1;
        $gene_site{alt_names} = $self->alt_names;
        $gene_site{site_type} =
          ( $self->strand eq "+" ) ? 'Splice Donor' : 'Splice Acceptor';
        $gene_site{ref_base}      = $self->get_base( $gene_site{abs_pos}, 1 );
        $gene_site{error_code}    = $self->transcript_error;
        $gene_site{transcript_id} = $self->transcript_id;
        $gene_site{strand}        = $self->strand;
        $self->add_flanking_sites( Seq::Site::Gene->new( \%gene_site ) );
      }
    }
  }
}

__PACKAGE__->meta->make_immutable;

1;
