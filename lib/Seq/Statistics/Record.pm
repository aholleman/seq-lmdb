package Seq::Statistics::Record;

use strict;
use warnings;
use 5.10.0;
our $VERSION = '0.001';

# ABSTRACT: A class for recording statistics
# VERSION

# This package essentially expects good inputs
# Meaning non-reference alleles at the least

use Moose::Role;

use Carp qw/cluck confess/;
use List::MoreUtils qw(first_index);
use syntax 'junction';

use DDP;

#provides deconvoluteGeno, hasGeno, isHomo, isHet
with 'Seq::Role::Genotypes', 'Seq::Role::Message';

requires 'isBadFeature';
requires 'statsKey';
requires 'statsRecord';
requires 'debug';

has countKey => (
  is      => 'rw',
  isa     => 'Str',
  lazy    => 1,
  default => 'count',
);

#href because the value corrsponds to the indices of _transitionTranvserionKeysAref
has _transitionTypesHref => (
  is       => 'ro',
  isa      => 'HashRef[Int]',
  traits   => ['Hash'],
  handles  => { isTr => 'get', },
  default  => sub { return { AG => 1, GA => 1, CT => 1, TC => 1, R => 1, Y => 1 } },
  lazy     => 1,
  init_arg => undef
);

has _transitionTransversionKeysAref => (
  is       => 'ro',
  isa      => 'ArrayRef[Str]',
  traits   => ['Array'],
  handles  => { trTvKey => 'get', },
  default  => sub { [ 'Transversions', 'Transitions' ] },
  lazy     => 1,
  init_arg => undef,
);

has _snpAnnotationsAref => (
  is       => 'ro',
  isa      => 'ArrayRef[Str]',
  traits   => ['Array'],
  handles  => { snpKey => 'get', },
  default  => sub { [ 'noRs', 'rs' ] },
  lazy     => 1,
  init_arg => undef,
);

# at every level in the has, record whether transition or transversion
# assumes that only non-reference alleles are passed, hence it is a role
sub record {
  my ( $self, $idGenoHref, $featuresAref, $refAllele, $geneDataAref, $snpDataAref ) =
    @_;
  #by order of complexity of left operand
  return unless defined $refAllele && @$featuresAref && @$geneDataAref;

  my @genoKeys = keys %$idGenoHref; #sampleIDs
  return unless @genoKeys;

  my (
    $geno,       $dGeno,       $annotationType, $sampleStats, $trTvKey,
    $targetHref, $minorAllele, $aCount,         @featuresMerged
  );

  #here we define anything that needn't be calculated per sample
  #if n+1 features we can put into sub
  my $snpKey;
  $snpKey = $self->snpKey( int( !!@$snpDataAref ) ) if defined $snpDataAref;
  #for now, analyze only
  for my $sampleID (@genoKeys) {
    $geno = $idGenoHref->{$sampleID};
    #this isn't as safe as $hasGeno, but saves ~1s per 20k lines over 100samples
    #but, should be ok, if we stick to conceit that homozygotes are 1 letter
    next unless $geno ne $refAllele; #require IUPAC geno, or D,I,E,H

    if ( !$self->hasStat($sampleID) ) { $self->setStat( $sampleID, {} ); }
    $targetHref = $self->getStat($sampleID);

    #we do this to avoid having to check against a string
    #because loose coupling good
    #stores tr, tv, and any other features
    $self->countCustomFeatures( $targetHref, $refAllele, $geno, $snpKey );

    next unless @$geneDataAref == 1; #for now we omit multiple transcript sites

    $aCount = $self->isHomo($geno) ? 2 : 1; #assumes diploid
    if ( !$aCount ) {
      $self->log( 'warn', 'No allele count found for genotype $geno' );
      next;
    }

    for my $annotationHref (@$geneDataAref) {
      $minorAllele = $annotationHref->minor_allele;
      # we do not check genotypes; multi-allelic sites not currently handled
      # nor are multi-transcript sites
      # if(!$self->hasGeno($self->deconvoluteGeno($geno), $minorAllele) ) {
      #   next;
      # }

      $annotationType = $annotationHref->annotation_type;

      if ( $self->debug ) {
        say "recording statistics for geno $geno, minorAllele $minorAllele, 
          annotation_type $annotationType";
      }
      #there is a more efficient option: just passing annotatypeType separately
      #I think this is cleaner (see use of shit in storeCount), and probably fast enough
      @featuresMerged = @{$featuresAref};
      push @featuresMerged, $annotationType;

      $self->storeCount( \@featuresMerged, $targetHref, $aCount );
    }
  }
}

#topTargetHref remains the top level hash, always gets transitions/transversion record
#because we want genome-wide tr:tv
#insertions and deletions don't have transitions and transversions, so check for that
sub storeCount {
  my ( $self, $featuresAref, $targetHref, $aCount ) = @_;

  #to be more efficient we could track a feature index, and return when
  #it == last featureAref index, and beyond that could store annotationType sep
  if ( !@$featuresAref ) { return; }
  my $feature = shift @$featuresAref;

  if ( $self->isBadFeature($feature) ) { return; }
  $targetHref = \%{ $targetHref->{$feature} };
  $targetHref->{ $self->statsKey }{ $self->countKey } += $aCount;

  @_ = ( $self, $featuresAref, $targetHref, $aCount );
  goto &storeCount; #tail call opt
}

# transitions are dependent only on the reference base and sample allele,
# they are, unlike geneDataAref features, a StatsCalculator created feature
# they should only be inserted in a single locaiton, else they'll be counted
# by sum(n*tr_i)
# by definition there can only be one tr or tv per site
# rs numbers are just like transitions and transversion
#we use defined check to find out whether anything exists; encapsulate here
#if it doesn't, presume the caller intended this not to be recorded as a non-snp site
#as a non-snp site
sub countCustomFeatures {
  my ( $self, $targetHref, $refAllele, $geno, $snpKey ) = @_;
  my $trTvKey =
    $self->trTvKey( $self->isTr($geno) || $self->isTr( $refAllele . $geno ) || 0 );
  $targetHref->{$trTvKey}{ $self->statsKey }{ $self->countKey } += 1;

  return unless defined $snpKey;
  $targetHref->{$snpKey}{ $self->statsKey }{ $self->countKey } += 1;
}

# if it's a het; currently supports only diploid organisms
# 2nd if isn't strictly necessary, but safer, and allows this to be used
# as an alternative to isHet, isHomo
# sub getAlleleCount {
#   my ($self, $iupacAllele) = @_;
#   if($self->isHomo($iupacAllele) ) {return 2;}
#   if($self->isHet($iupacAllele) ) {return 1;}
#   return;
# }

no Moose::Role;
1;
