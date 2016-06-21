use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class B<Seq::Gene>
  
  Note: unlike previous SeqAnt, there is no longer a genomic_type
  Just a siteType, which is Intronic, Coding, 5UTR, etc
  This is just like Annovar's
  We add "Intergenic" if not covered by any gene

  This class also handles intergenic sites

=cut

use Moose 2;

use namespace::autoclean;
use DDP;

extends 'Seq::Tracks::Get';

use Seq::Tracks::Gene::Site;
use Seq::Tracks::Gene::Site::SiteTypeMap;
use Seq::Tracks::Gene::Site::CodonMap;

#exports regionTrackPath, regionNearestSubTrackName
with 'Seq::Tracks::Region::Definition',
#allUCSCgeneFeatures
'Seq::Tracks::Gene::Definition',
#dbReadAll
'Seq::Role::DBManager';

### objects that get used by multiple subs, but shouldn't be public attributes ###
state $siteUnpacker = Seq::Tracks::Gene::Site->new();
state $siteTypeMap = Seq::Tracks::Gene::Site::SiteTypeMap->new();
state $codonMap = Seq::Tracks::Gene::Site::CodonMap->new();

### Additional "features" that we will add to our output ###
state $refAminoAcidKey = 'referenceAminoAcid';
state $newAminoAcidKey = 'newAminoAcid';
state $nearestSubTrackName = 'nearest';
state $txEffectsKey = 'proteinEffect';

### Positions that aren't covered by a refSeq record are intergenic ###
state $intergenic = 'Intergenic';

### txEffect possible values ###
state $nonCoding = 'NonCoding';
state $silent = 'Silent';
state $replacement = 'Replacement';
state $frameshift = 'Frameshift';
state $inFrame = 'InFrame';
state $startLoss = 'StartLoss';
state $stopLoss = 'StopLoss';
state $truncated = 'TruncatedCodon';

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub{ my $self = shift; return $self->allUCSCgeneFeatures; },
);

### Cache self->getFieldDbName calls to save a bit on performance & improve readability ###
state $allCachedDbNames;

#### Add our other "features", everything we find for this site ####
override 'BUILD' => sub {
  my $self = shift;

  $self->addFeaturesToHeader([$siteUnpacker->allSiteKeys, $txEffectsKey, 
    $refAminoAcidKey, $newAminoAcidKey], $self->name);

  my @nearestFeatureNames = $self->allNearestFeatureNames;
  
  if(@nearestFeatureNames) {
    $self->addFeaturesToHeader( [ map { "$nearestSubTrackName.$_" } @nearestFeatureNames ], $self->name);
  }

  ####Build up a list of fieldDbNames; these are called millions of times ######
  #Doing this before $self->get, which may be threaded, allows us to also memoize
  #getFieldDbName results
  $allCachedDbNames->{$self->name} = {
    #nearest gene is a pseudo-track, stored as it's own key, outside of
    #$self->name, but in a unique name based on $self->name, private to this class
    $self->regionNearestSubTrackName => $self->getFieldDbName($self->regionNearestSubTrackName),
  };

  for my $featureName ($self->allFeatureNames) {
    $allCachedDbNames->{$self->name}->{$featureName} = $self->getFieldDbName($featureName);
  }

  #the features specified in the region database which we want for nearest gene records
  for my $nearestFeatureName ($self->allNearestFeatureNames) {
    $allCachedDbNames->{$self->name}->{$nearestFeatureName} = $self->getFieldDbName($nearestFeatureName);
  }

  super();
};

#gets the gene, nearest gene data for the position
#also checks for indels
#@param <String|ArrayRef> $allelesAref : the alleles (including ref potentially)
# that are found in the user's experiment, for this position that we're annotating
#@param <Number> $dbPosition : The 0-index position of the current data
sub get {
  my ($self, $href, $chr, $dbPosition, $refBase, $allelesAref) = @_;

  # Cached field names to make things easier to read
  my $cachedDbNames = $allCachedDbNames->{$self->name};

  ################# Cache track's region data ##############
  state $geneTrackRegionHref = {};
  if(!defined $geneTrackRegionHref->{$self->name}->{$chr} ) {
    $geneTrackRegionHref->{$self->name}->{$chr} = $self->dbReadAll( $self->regionTrackPath($chr) );
  }

  my $regionData = $geneTrackRegionHref->{$self->name}->{$chr};

  ####### Get all transcript numbers, and site data for this position #########
  my (@txNumbers, @siteData);

  # is an <ArrayRef[ArrayRef>|ArrayRef[Int]>, each Aref is [$referenceNumberToRegionDatabase, $siteData] ]
  if( $href->{$self->dbName} ) {
    if( ref $href->{$self->dbName}->[0] ) {
      foreach ( @{ $href->{$self->dbName} } ) {
        push @txNumbers, $_->[0];
        push @siteData, $_->[1];
      }
    } else {
      push @txNumbers, $href->{$self->dbName}->[0];
      push @siteData, $href->{$self->dbName}->[1]; 
    }
  }
  
  my %out;

  ################# Populate nearestGeneSubTrackName ##############
  if(!$self->noNearestFeatures) {
    # Nearest genes are sub tracks, stored under their own key, based on $self->name
    # <Int|ArrayRef[Int]>
    # If we're in a gene, we won't have a nearest gene reference
    my $nearestGeneNumber = $href->{ $cachedDbNames->{$self->regionNearestSubTrackName} } || \@txNumbers;

    if($nearestGeneNumber) {
      for my $geneRef ( ref $nearestGeneNumber ? @$nearestGeneNumber : $nearestGeneNumber ) {
          for my $nFeature ($self->allNearestFeatureNames) {
            push @{ $out{"$nearestSubTrackName.$nFeature"} },
              $regionData->{$geneRef}->{ $cachedDbNames->{$nFeature} };
          }
      }
    } else { $self->log('warn', "no " . $self->name . " or " . $self->regionNearestSubTrackName . " found"); }
  }

  ################# Check if this position is in a place covered by gene track #####################
    
  if(! $href->{$self->dbName} ) {
    #if not, state that the siteType is intergenic!
    $out{$siteUnpacker->siteTypeKey} = $intergenic;
    return \%out;
  }

  if( @txNumbers == 0 || @siteData == 0 || @txNumbers != @siteData ) {
    $self->log('warn', "Position $chr:@{[$dbPosition+1]} covered a gene, but was " .
      "missing either a txNumber, or siteData. This is a database build error");
    return \%out;
  }

  ################# Populate geneTrack's user-defined features #####################
  foreach ($self->allFeatureNames) {
    INNER: for my $txNumber (@txNumbers) {
      push @{ $out{$_} }, $regionData->{$txNumber}{ $cachedDbNames->{$_} };
    }
  }

  ################## Populate site information ########################
  # save unpacked sites, for use in txEffectsKey population #####
  my @unpackedSites;
  foreach (@siteData) {
    #update the item in the array, to avoid allocating a new array for the purpose
    my $site = $siteUnpacker->unpackCodon($_);

    CODON_LOOP: for my $key (keys %$site) {
      #### Populate refAminoAcidKey; note that for a single site
      ###    we can have only one codon sequence, so not need to set array of them ###
      if(!defined $site->{$key}) {
        next CODON_LOOP;
      }

      #If we have a codon, add it
      if($key eq $siteUnpacker->codonSequenceKey) {
        push @{ $out{$refAminoAcidKey} }, $codonMap->codon2aa( $site->{$key} );

        #if it's not a full transcript, let the user know
        #note that will mean codon2aa returns undef, which is what is wanted
        #since all undefined values become NA
        if(length( $site->{$key} ) != 3) {
          push @{ $out{$key} }, $truncated;
          next CODON_LOOP;
        }
      }

      push @{ $out{$key} }, $site->{$key};
    }

    push @unpackedSites, $site; #save for us in txEffects;
  }

  ################# Populate $transcriptEffectsKey, $refAminoAcidKey, and $newAminoAcidKey #####################
  ################# We include analysis of indels here, becuase  
  #############  we may want to know how/if they disturb genes  #####################

  # Looping over string, int, or ref: https://ideone.com/4APtzt
  TX_EFFECTS_LOOP: for my $allele (ref $allelesAref ? @$allelesAref : $allelesAref) {
    my @accum;

    if(length($allele) > 1) {
      # We expect either a + or -
      my $type = substr($allele, 0, 1);

      #store as array because our output engine writes [ [one], [two] ] as "1,2"
      push @accum, [ $self->_annotateIndel($chr, $dbPosition, $allele) ];

      next TX_EFFECTS_LOOP;
    }

    ######### Most cases are just snps, so  inline that functionality ##########
    state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };

    ### We only populate newAminoAcidKey for snps ###
    SNP_LOOP: for (my $i = 0; $i < @unpackedSites; $i++ ) {

      my $refCodonSequence = $unpackedSites[$i]->{ $siteUnpacker->codonSequenceKey };

      if(!$refCodonSequence) {
        push @accum, $nonCoding;
        push @{ $out{$newAminoAcidKey} }, undef;

        next SNP_LOOP;
      }

      if(length($refCodonSequence) != 3) {
        $self->log('warn', "Codon @ $chr: @{[$dbPosition + 1]} not 3 bases long: $refCodonSequence");
        
        push @accum, $truncated;
        push @{ $out{$newAminoAcidKey} }, undef;
        
        next SNP_LOOP;
      }

      # If codon is on the opposite strand, invert the allele
      if( $unpackedSites[$i]->{ $siteUnpacker->strandKey } eq '-' ) {
        $allele = $negativeStrandTranslation->{$allele};
      }

      #make a codon where the reference base is swapped for the allele
      my $alleleCodonSequence = $refCodonSequence;
      
      substr($alleleCodonSequence, $unpackedSites[$i]->{ $siteUnpacker->codonPositionKey }, 1 ) = $allele;

      push @{ $out{$newAminoAcidKey} }, $codonMap->codon2aa($refCodonSequence);
            
      # say "allele is $allele, position is $unpackedSites[$i]->{ $siteUnpacker->codonPositionKey }";
      # say "new aa is $refCodonSequence";

      # If reference codon is same as the allele-substititued version, it's a Silent site
      if( $codonMap->codon2aa($refCodonSequence) eq $out{$newAminoAcidKey}->[$i] ) {
        push @accum, $silent;
      } else {
        push @accum, $replacement;
      }
    }

    if(@accum) {
      push @{ $out{$txEffectsKey} }, @accum > 1 ? \@accum : $accum[0];
    }
  }

  if( !defined $out{$txEffectsKey} ) {
    $out{$txEffectsKey} = $intergenic;
  } elsif( @{ $out{$txEffectsKey} } == 1) {
    $out{$txEffectsKey} = $out{$txEffectsKey}->[0];
  }

  return \%out;
};

sub _annotateIndel {
  my ($self, $chr, $dbPosition, $allele) = @_;

  my $beginning = '';
  my $middle = '';

  my $dbDataAref;

  my $type = substr($allele, 0, 1);
  #### Check if insertion or deletion ###
  if($type eq '+') {
    #insetion
    $beginning = (length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame) . "[";

    #by passing the dbRead function an array, we get an array of data back
    #even if it's one position worth of data
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + 1 ] );
  } elsif($type eq '-') {
    #deletion
    $beginning = ($allele % 3 ? $frameshift : $inFrame) . "[";
    
    #get everything including the current dbPosition, in order to simplify code
    #small perf hit because few indels
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + $allele .. $dbPosition ] );
  } else {
    $self->log("warn", "Can't recognize allele $allele on $chr:@{[$dbPosition + 1]}
      as valid indel (must start with - or +)");
    return undef;
  }

  for my $data (@$dbDataAref) {
    if (! defined $data->{ $self->dbName } ) {
      #this position doesn't have a gene track, so skip
      $middle .= "$intergenic";
      next;
    }
   
    ####### Get all transcript numbers, and site data for this position #########
    my $siteData;

    # is an <ArrayRef[ArrayRef>|ArrayRef[Int]>, each Aref is [$referenceNumberToRegionDatabase, $siteData] ]
    if( $data->{$self->dbName} ) {
      if( ref $data->{$self->dbName}->[0] ) {
        foreach ( @{ $data->{$self->dbName} } ) {
          push @$siteData, $_->[1];
        }
      } else {
        $siteData = $data->{$self->dbName}->[1]; 
      }
    }

    for my $oneSiteData (ref $siteData ? @$siteData : $siteData) {
      my $site = $siteUnpacker->unpackCodon($oneSiteData);

      #Accumulate the annotation. We aren't using Seq::Output to format, because
      #it doesn't fit well with this scheme, in which we prepend FrameShift[ and append ]
      if ( defined $site->{ $siteUnpacker->codonNumberKey } && $site->{ $siteUnpacker->codonNumberKey } == 1 ) {
        $middle .= "$startLoss;";
      } elsif ( defined $site->{ $siteUnpacker->codonSequenceKey }
      &&  $codonMap->codon2aa( $site->{ $siteUnpacker->codonSequenceKey } ) eq '*' ) {
        $middle .= "$stopLoss;";
      } else {
        $middle .= $site->{ $siteUnpacker->siteTypeKey } . ";";
      }
    }
  }
  
  chop $middle;

  return $beginning . $middle . "]";
}

__PACKAGE__->meta->make_immutable;

1;
