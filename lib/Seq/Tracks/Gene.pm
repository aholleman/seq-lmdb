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

use Carp qw/ confess /;
use namespace::autoclean;
use DDP;


extends 'Seq::Tracks::Get';

use Seq::Tracks::Gene::Site;
use Seq::Tracks::Gene::Site::SiteTypeMap;
use Seq::Tracks::Gene::Site::CodonMap;

#exports regionTrackPath
with 'Seq::Tracks::Region::Definition',
#siteFeatureName, defaultUCSCgeneFeatures, nearestGeneFeatureName
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
state $nonCoding = 'Non-Coding';
state $silent = 'Silent';
state $replacement = 'Replacement';
state $frameshift = 'Frameshift';
state $inFrame = 'InFrame';
state $startLoss = 'StartLoss';
state $stopLoss = 'StopLoss';
state $truncated = 'TruncatedCodon';

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub{ my $self = shift; return $self->defaultUCSCgeneFeatures; },
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
    $self->addFeaturesToHeader( [ map { "$nearestSubTrackName.$_" } @nearestFeatureNames ], 
      $self->name);
  }

  ####Build up a list of fieldDbNames; these are called millions of times ######
  #Doing this before $self->get, which may be threaded, allows us to also memoize
  #getFieldDbName results
  $allCachedDbNames->{$self->name} = {
    #nearest gene is a pseudo-track, stored as it's own key, outside of
    #$self->name, but in a unique name based on $self->name that is defined
    #by the gene track (in the future region tracks will follow this method)
    $self->nearestGeneFeatureName => $self->getFieldDbName($self->nearestGeneFeatureName),
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

  # is an <ArrayRef> of [ [$referenceNumberToRegionDatabase, $siteData], ... ]
  my $trackDataAref = $href->{$self->dbName};

  ####### Get all transcript numbers, and site data for this position #########
  my (@txNumbers, @siteData);
  for my $dataAref (@$trackDataAref) {
    #$dataAref[0] is the txNumber in each pair
    #the region database keys are txNumber(s)
    push @txNumbers, $regionData->{$dataAref->[0]};
    push @siteData, $regionData->{$dataAref->[1]}; 
  }

  my %out;

  ################# Populate nearestGeneSubTrackName ##############
  if(!$self->noNearestFeatures) {
    # nearest genes are sub tracks, stored under their own key, based on $self->name
    # this is a reference to something stored in the gene tracks' region database
    my $nearestGeneNumber = $href->{$self->nearestGeneFeatureName};

    #may not have one at the end of a chromosome
    #and no nearest gene reference is given for sites in a gene
    if($nearestGeneNumber) {
      for my $nFeature ($self->allNearestFeatureNames) {
        $out{"$nearestSubTrackName.$nFeature"} =
          $regionData->{$nearestGeneNumber}->{ $cachedDbNames->{$nFeature} };
      }
    } elsif(@txNumbers) {
      #TODO: could reduce { } to unique set, to lessen chances of multiple identical sites
      #in case of multiple transcripts covering
      foreach (@txNumbers) {
        for my $nFeature ($self->allNearestFeatureNames) {
          $out{"$nearestSubTrackName.$nFeature"} = $regionData->{$_}->{ $cachedDbNames->{$nFeature} };
        }
      }
    } else {
      $self->log('warn', "no " . $self->name . " or " . $self->nearestGeneFeatureName . " found");
    }
  } 

  ################# Check if this position is in a place covered by gene track #####################
  if(!$trackDataAref) {
    #if not, state that the siteType is intergenic!
    $out{$self->siteTypeKey} = $intergenic;
    return \%out;
  }

  ################# Populate geneTrack's user-defined features #####################
  foreach ($self->allFeatureNames) {
    INNER: for my $txNumber (@txNumbers) {
      #dataAref == [$txNumber, $siteData]
      push @{ $out{$_} }, $regionData->{$txNumber}{ $cachedDbNames->{$_} };
    }
  }

  ################## Populate site information ########################
  if( !@txNumbers || !@siteData ) {
    $self->log('warn', "Position $chr:@{[$dbPosition+1]} covered a gene, but was " .
      "missing either a txNumber, or siteData. This is a database build error");
    
    return \%out;
  }

  ################# Populate all $siteUnpacker->allSiteKeys and $retionTypeKey #####################
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
        if(length( $site->${key} ) != 3) {
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
  my @alleles = ref $allelesAref ? @$allelesAref : ($allelesAref);

  TX_EFFECTS_LOOP: for my $allele (@alleles) {
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

    # say "number of unpacked codons is: " . scalar @unpackedSites;
    ### We only populate newAminoAcidKey for snps ###
    SNP_LOOP: for (my $i = 0; $i < @unpackedSites; $i++ ) {
      my $refCodonSequence = $unpackedSites[$i]->{ $siteUnpacker->codonSequenceKey };

      if(!$refCodonSequence) {
        push @accum, $nonCoding;
        push @{ $out{$newAminoAcidKey} }, undef;

        next SNP_LOOP;
      }

      if(length($refCodonSequence) != 3) {
        $self->log('warn', "The codon @ $chr: @{[$dbPosition + 1]}" .
          " isn't 3 bases long: $refCodonSequence");
        
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

  my $beginning;
  
  my $dbDataAref;
  #### Check if insertion or deletion ###
  if(substr($allele, 0, 1) eq '+') {
    #insetion
    $beginning = (length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame) ."[";

    #by passing the dbRead function an array, we get an array of data back
    #even if it's one position worth of data
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + 1 ] );
  } elsif(substr($allele, 0, 1) eq '-') {
    #deletion
    $beginning = ($allele % 3 ? $frameshift : $inFrame) ."[";
    
    $dbDataAref = $self->dbRead( $chr, [ $dbPosition + $allele .. $dbPosition ] );
  } else {
    $self->log("warn", "Can't recognize allele $allele on $chr:@{[$dbPosition + 1]}
      as valid indel (must start with - or +)");
    return undef;
  }

  my $count = 0;
  for my $data (@$dbDataAref) {
    if (! defined $data->{ $self->dbName } ) {
      #this position doesn't have a gene track, so skip
      $beginning .= "$intergenic";
      next;
    }

    if($count++ > 1) {
      #separate different positions by a pipe to denote difference from alleles and
      #transcripts (transcripts separated by a ";")
      substr($beginning, -1, 1) = "|";
    }
      
   

    my $siteData = $data->{ $self->dbName }->{
      $allCachedDbNames->{$self->name}->{$self->siteFeatureName} };

    if(! ref $siteData ) {
      $siteData = [$siteData];
    }

    for my $oneSiteData (@$siteData) {
      my $site = $siteUnpacker->unpackCodon($oneSiteData);

      if ( defined $site->{ $siteUnpacker->codonNumberKey } && $site->{ $siteUnpacker->codonNumberKey } == 1 ) {
        $beginning .= "$startLoss;";
      } elsif ( defined $site->{ $siteUnpacker->codonSequenceKey }
      &&  $codonMap->codon2aa( $site->{ $siteUnpacker->codonSequenceKey } ) eq '*' ) {
        $beginning .= "$stopLoss;";
      } else {
        $beginning .= $site->{ $siteUnpacker->siteTypeKey } . ";";
      }
    }
  }
  
  chop $beginning;
  return "beginning]";
}

__PACKAGE__->meta->make_immutable;

1;
