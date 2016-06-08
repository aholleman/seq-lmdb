use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene;

our $VERSION = '0.001';

=head1 DESCRIPTION

  @class B<Seq::Gene>
  
  Takes a hash ref (which presumably comes from the database)
  And returns a hash ref with {
    feature1 => value1,
    etc
  }

  Also adds a regionType, siteType, and txEffects key
  
  Handles indels

=cut

use Moose 2;

use Carp qw/ confess /;
use namespace::autoclean;
use DDP;


extends 'Seq::Tracks::Get';

use Seq::Tracks::Gene::Site;

#regionReferenceFeatureName and regionTrackPath
with 'Seq::Tracks::Region::Definition',
#siteFeatureName, defaultUCSCgeneFeatures, nearestGeneFeatureName
'Seq::Tracks::Gene::Definition',
#dbReadAll
'Seq::Role::DBManager';

### Additional "features" that we will add to our output ###
state $refAminoAcidKey = 'referenceAminoAcid';
state $newAminoAcidKey = 'newAminoAcid';
state $regionTypeKey = 'regionType';
state $nearestGeneSubTrackName = 'nearest';
state $siteTypeKey = 'siteType';
state $txEffectsKey = 'txEffect';

### region type possible values ###
state $intergenic = 'Intergenic';
state $intronic = 'Intronic';
state $exonic = 'Exonic';

### txEffect possible values ###
state $silent = 'Silent';
state $replacement = 'Replacement';
state $frameshift = 'Frameshift';
state $inFrame = 'InFrame';
state $startLoss = 'StartLoss';
state $stopLoss = 'StopLoss';
state $truncated = 'TruncatedCodon';

### objects that get used by multiple subs, but shouldn't be public attributes ###
state $siteUnpacker = Seq::Tracks::Gene::Site->new();

### Set the features that we get from the Gene track region database ###
has '+features' => (
  default => sub{ my $self = shift; return $self->defaultUCSCgeneFeatures; },
);

### Cache self->getFieldDbName calls to save a bit on performance & improve readability ###
state $allCachedDbNames;

#### Add our other "features", everything we find for this site ####
override 'BUILD' => sub {
  my $self = shift;

  $self->addFeaturesToHeader([$siteUnpacker->allSiteKeys, $regionTypeKey,
    $siteTypeKey, $txEffectsKey, $refAminoAcidKey, $newAminoAcidKey], $self->name);

  my @nearestFeatureNames = $self->allNearestFeatureNames;
  
  if(@nearestFeatureNames) {
    $self->addFeaturesToHeader( [ map { "$nearestGeneSubTrackName.$_" } @nearestFeatureNames ], 
      $self->name);
  }

  ###Build up a list of fieldDbNames; these are called millions of times ###
  $allCachedDbNames->{$self->name} = {
    $self->siteFeatureName => $self->getFieldDbName($self->siteFeatureName),
    $self->nearestGeneFeatureName => $self->getFieldDbName($self->nearestGeneFeatureName),
    $self->regionReferenceFeatureName => $self->getFieldDbName($self->regionReferenceFeatureName),
  };

  for my $featureName ($self->allFeatureNames) {
    $allCachedDbNames->{$self->name}->{$featureName} = $self->getFieldDbName($featureName);
  }

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

  #### Get all of the region data if not already fetched
  #we expect the region database to look like
  # {
  #  someNumber => {
  #    $self->name => {
  #     someFeatureDbName1 => val1,
  #     etc  
  #} } }
  state $geneTrackRegionHref = {};
  if(!defined $geneTrackRegionHref->{$self->name}->{$chr} ) {
    $geneTrackRegionHref->{$self->name}->{$chr} = $self->dbReadAll( $self->regionTrackPath($chr) );
  }

  my $regionData = $geneTrackRegionHref->{$self->name}->{$chr};

  # Gene track data stored in the main database, for this position
  my $geneData = $href->{$self->dbName};
  
  # Cached field names to avoid extra $self->dbName overhead, easier to read
  my $cachedDbNames = $allCachedDbNames->{$self->name};

  my %out;

  ################# Populate nearestGeneSubTrackName ##############
  if(!$self->noNearestFeatures) {
    #get the database name of the nearest gene track
    #but this never changes, so store as static

    # this is a reference to something stored in the gene tracks' region database
    my $nearestGeneNumber = $geneData->{ $cachedDbNames->{$self->nearestGeneFeatureName} };

    #may not have one at the end of a chromosome
    if($nearestGeneNumber) {
      
      #get the nearest gene data
      #outputted as "nearest.someFeature" => value if "nearest" is the nearestGeneFeatureName
      for my $nFeature ($self->allNearestFeatureNames) {
        $out{"$nearestGeneSubTrackName.$nFeature"} = $regionData->{$nearestGeneNumber}
          ->{$self->dbName}->{ $cachedDbNames->{$nFeature} };
      }
      
    }
  } 

  ################# Check if this position is in a place covered by gene track #####################
  #a single position may cover one or more sites
  #we expect either a single value (href in this case) or an array of them

  # if $href has
  # {
  #  $self->regionReferenceFeatureName => someNumber
  #}
  #this position covers these genes
  my $geneRegionNumberRef = $geneData->{ $cachedDbNames->{$self->regionReferenceFeatureName} };

  ################# Populate $regionTypeKey if no gene is covered #####################
  if(!$geneRegionNumberRef) {
    #if we don't have a gene at this site, it's Integenic
    #this is the lowest index item
    $out{$regionTypeKey} = $intergenic;
    
    return \%out;
  }

  ################# Populate geneTrack's user-defined features #####################
  my $regionDataAref;
  if(ref $geneRegionNumberRef) {
    $regionDataAref = [ map { $regionData->{$_}->{$self->dbName} } @$geneRegionNumberRef ];
  } else {
    $regionDataAref = [ $regionData->{$geneRegionNumberRef}->{$self->dbName} ];
  }
  
  #now go from the database feature names to the human readable feature names
  #and include only the featuers specified in the yaml file
  #each $pair <ArrayRef> : [dbName, humanReadableName]
  #and if we don't have the feature, that's ok, we'll leave it as undefined
  #also, if no features specified, then just get all of them
  #better too much than too little
  for my $featureName ($self->allFeatureNames) {
    INNER: for my $geneDataHref (@$regionDataAref) {
      if(defined $out{$featureName} ) {
        #check if this value has already been made an array
        if(ref $out{$featureName} ne 'ARRAY') {
          $out{$featureName} = [ $out{$featureName} ];
        }

        #could be pushing undefined valueundefined
        push @{ $out{$featureName} }, $geneDataHref->{ $cachedDbNames->{$featureName} };
        
        next INNER;
      }
      #could be undefined
      $out{ $featureName } = $geneDataHref->{ $cachedDbNames->{$featureName} };
    }
  }

  my $siteDetailsRef = $geneData->{ $cachedDbNames->{$self->siteFeatureName} };

  ########### Check if allele is an insertion or deletion, and if so, get siteDetails for each of them #########

  #if deletion, get all sites covered by the deletion
  #if insertion, get the next site over, because insertions insert 1 position
  #up from the current position

  my @unpackedSites;
  ################## Populate site information ########################
  if( !$siteDetailsRef ) {
    $self->log('warn', "Position $chr:@{[$dbPosition+1]} was covered by a gene" .
      " but didn't have site info. This is a database build error");
    
    $out{$regionTypeKey} = undef;
    $out{$siteTypeKey} = undef;
    #return \%out;
  } else {
    ################# Populate all $siteUnpacker->allSiteKeys and $retionTypeKey #####################
    if(!ref $siteDetailsRef) {
      $siteDetailsRef = [$siteDetailsRef];
    }

    for (my $i = 0; $i < @$siteDetailsRef; $i++) {
      #update the item in the array, to avoid allocating a new array for the purpose
      push @unpackedSites, $siteUnpacker->unpackCodon($siteDetailsRef->[$i]);

      for my $key (keys %{ $unpackedSites[$i] }) {
        #### Populate the regionTypeKey, which can be Exonic or Intronic ###
        if($key eq $siteUnpacker->siteTypeKey) {
          if( $siteUnpacker->siteTypeMap->isExonicSite( $unpackedSites[$i]{$key} ) ) {
            $out{$regionTypeKey} = $exonic;
          }
        }

        #### Populate refAminoAcidKey; note we always set array; at
        ###      end of file, reduce back to string #####################
        if($key eq $siteUnpacker->codonSequenceKey) {
          push @{ $out{$refAminoAcidKey} }, defined $unpackedSites[$i]{$key} ?
            $siteUnpacker->codonMap->codon2aa( $unpackedSites[$i]{$key} ) : undef;
        }

        if(exists $out{$key} ) {
          if(ref $out{$key} ne 'ARRAY') {
            $out{$key} = [$out{$key}];
          }

          push @{ $out{$key} }, $unpackedSites[$i]{$key};
          next;
        }

        $out{$key} = $unpackedSites[$i]{$key};
      }
    }

    ### If regionTypeKey not defined we didn't find isExonicSite(), so Intronic
    if(! $out{$regionTypeKey} ) {
      $out{$regionTypeKey} = $intronic;
    }
  }

  ################# Populate $transcriptEffectsKey, $refAminoAcidKey, and $newAminoAcidKey #####################
  ################# We include analysis of indels here, becuase  
  #############  we may want to know how/if they disturb genes  #####################
  my @alleles = ref $allelesAref ? @$allelesAref : ($allelesAref);

  state $indelTypeMap = {
    '-' => 'Deletion',
    '+' => 'Insertion',
  };

  #<ArrayRef|String>
  #$out{$txEffectsKey};

  # #### Populate reference amino acid keys ####
    # if(defined $out{$siteUnpacker->codonSequenceKey} ) {
    #   if(ref $out{$siteUnpacker->codonSequenceKey} ) {
    #     $out{$refAminoAcidKey} = [ map { $siteUnpacker->codonMap->codon2aa($_) } 
    #       @{ $out{$siteUnpacker->codonSequenceKey} } ]
    #   } else {
    #     push $out{$refAminoAcidKey}, defined $_ ? $siteUnpacker->codonMap->codon2aa($_) : undef
    #   }
    # } else {
    #   $out{$refAminoAcidKey} = undef;
    # }

  for my $allele (@alleles) {
    my @accum;
    if(length($allele) > 1) {
      my $type = substr($allele, 0, 1);

      if($type eq '+') {
        #insertion

        push @accum, $self->_annotateInsertion($dbPosition, $allele);
        next;
      }

      if($type eq '-') {
        #deletion

        push @accum, $self->_annotateDeletion($dbPosition, $allele, \@unpackedSites);
        next;
      }

      $self->log('warn', "Can't recognize allele $allele for $chr:@{[$dbPosition+1]}");
      next;
    }

    ### Most cases are just snps, so we will inline that functionality
    state $negativeStrandTranslation = { A => 'T', C => 'G', G => 'C', T => 'A' };


    # say "number of unpacked codons is: " . scalar @unpackedSites;
    ### We only populate newAminoAcidKey for snps ###
    SNP_LOOP: for (my $i = 0; $i < @unpackedSites; $i++ ) {
      my $codonSequence = $unpackedSites[$i]->{ $siteUnpacker->codonSequenceKey };

      # say "i is $i";

      # say "codon Sequence is " . (defined $codonSequence ? $codonSequence : 'undefined');
      
      if(!$codonSequence) {
        push @accum, "Non-Coding";

        next SNP_LOOP;
      }

      if(length($codonSequence) != 3) {
        $self->log('warn', "The codon @ $chr: @{[$dbPosition + 1]}" .
          " isn't 3 bases long: $codonSequence");
        
        push @accum, $truncated;
        next SNP_LOOP;
      }

      # If codon is on the opposite strand, invert the allele
      if( $unpackedSites[$i]->{ $siteUnpacker->strandKey } eq '-' ) {
        $allele = $negativeStrandTranslation->{$allele};
      }

      #make a codon where the reference base is swapped for the allele
      substr($codonSequence, $unpackedSites[$i]->{ $siteUnpacker->codonPositionKey }, 1 ) = $allele;

      # say "allele is $allele, position is $unpackedSites[$i]->{ $siteUnpacker->codonPositionKey }";
      # say "new aa is $codonSequence";

      # If reference codon is same as the allele-substititued version, it's a Silent site
      if( $out{$refAminoAcidKey}->[$i] eq $siteUnpacker->codonMap->codon2aa($codonSequence) ) {
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
  }

  if( @{ $out{$txEffectsKey} } == 1) {
    $out{$txEffectsKey} = $out{$txEffectsKey}->[0];
  }

  #reduce to string, maybe faster printing, since no need to traverse array
  if( @{ $out{$refAminoAcidKey} } == 1) {
    $out{$refAminoAcidKey} = $out{$refAminoAcidKey}->[0];
  }

  # say "txEffects are " . join(";", @{ $out{$txEffectsKey} } );
 # p $out{$txEffectsKey};

  return \%out;
};

sub _annotateInsertion {
  my ($self, $chr, $dbPosition,, $allele) = @_;

  my $out = (length( substr($allele, 1) ) % 3 ? $frameshift : $inFrame) ."[";

  my $nextData = $self->dbRead($chr, $dbPosition + 1);

  if (! defined $nextData->{ $self->dbName } ) {
    say "nextData doesn't have geneTrack, result is : '$out$intergenic];'";
    return "$out$intergenic];";
  }

  my $nextSiteDataRef = $nextData->{ $self->dbName }->{ 
    $allCachedDbNames->{$self->name}->{$self->siteFeatureName} };

  if(!ref $nextSiteDataRef) {
    $nextSiteDataRef = [$nextSiteDataRef];
  }

  for my $nextSiteData (@$nextSiteDataRef) {
    if ( $nextSiteData->{ $siteUnpacker->codonNumberKey } == 1 ) {
      $out .= "$startLoss;";
    } elsif ( $nextSiteData->{ $siteUnpacker->peptideKey } eq '*' ) {
      $out .= "$stopLoss;";
    } else {
      $out .= $nextSiteData->{ $siteUnpacker->siteTypeKey } . ";";
    }
  }

  chop $out;

  return "$out]";
}

sub _annotateDeletion {
  my ($self, $chr, $dbPosition, $allele, $unpackedSitesAref) = @_;

  my @out;

  #https://ideone.com/ydQtgU
  my $frameLabel = $allele % 3 ? $frameshift : $inFrame;

  my $nextDataAref = $self->dbRead($chr, $dbPosition + $allele);

  my $beginning = ($allele % 3 ? $frameshift : $inFrame) . "[";
  my $end = "]";

  my $count = 0;
  my $pushUnpackedSites;
  for my $nextData (@$nextDataAref) {
    $count++;

    if (! defined $nextData->{ $self->dbName } ) {
      $beginning .= "$intergenic;";

      if ($count == @$nextDataAref) {
        $pushUnpackedSites = 1;
      } else {
        next;
      }
    }
    
    my $nextSiteDataRef = $nextData->{ $self->dbName }->{ 
      $allCachedDbNames->{$self->name}->{$self->siteFeatureName} };

    if(! ref $nextSiteDataRef ) {
      $nextSiteDataRef = [$nextSiteDataRef];
    }

    if ($pushUnpackedSites) {
      if(@$unpackedSitesAref) {
        push @$nextSiteDataRef, @$unpackedSitesAref;
      }
    }

    say "nextSiteDataRef is";
    p $nextSiteDataRef;

    for my $nextSiteData (@$nextSiteDataRef) {
      if ( $nextSiteData->{ $siteUnpacker->codonNumberKey } == 1 ) {
        $beginning .= "$startLoss;";
      } elsif ( $nextSiteData->{ $siteUnpacker->peptideKey } eq '*' ) {
        $beginning .= "$stopLoss;";
      } else {
        $beginning .= $nextSiteData->{ $siteUnpacker->siteTypeKey } . ";";
      }
    }
  }

  chop $beginning;
  say "deletion transcript effects are : '$beginning]'";
  return "$beginning]";
}

__PACKAGE__->meta->make_immutable;

1;
