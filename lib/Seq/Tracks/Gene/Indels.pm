use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Gene::Indels;

our $VERSION = '0.001';

# ABSTRACT: A class for annotating indels
# VERSION

use Moose;
use DDP;

with 'Seq::Role::DBManager';

sub _getIndelType {
  # my ($self, $allele) = @_;
  #$_[1] == $allele
  return substr( "" . $_[1], 0, 1 );
}

# we only allow numeric for deletions;
# we could also do the check around
sub _getIndelLength {
  my ($self, $type, $allele) = @_;
  if ( $type eq '-' ) {
    return abs( int( $allele ) );
  }
  return length( substr( $self->minor_allele, 1 ) );
}

my $typNamesMap = {
  '-' => 'Del',
  '+' => 'Ins',
};

sub _getFrameType {
  my ( $self, $length ) = @_;
  return $length % 3 ? 'FrameShift' : 'InFrame';
}

sub findGeneData {
  my ( $self, $thisPositionDataHref, $allele, $dbPosition ) = @_;

  my @data;
  my @range; #can't pass list to db_get
  my $annotationType;
  my $reconstitutedAllele = ''; 

  my ($alleleType, $alleleLength) = _describeAllele($allele);

  my $dbDataAref;
  if($alleleType eq 'Del') {
    #get all of the data from deleted allele
    $dbDataAref = $self->dbRead([ $dbPosition - ($alleleLength - 1) .. $dbPosition - 1]);


    return $self->_annotateSuge($dbDataAref, $allele);
  } else {
    $dbDataAref = $self->dbRead([ $dbPosition .. $dbPosition - 1]);
  }
    if ( $allele->indType eq '-' ) {
      #inclusive of current base
      @range = ( $abs_pos - $allele->indLength + 1 .. $abs_pos );
      @data = $db->db_bulk_get( \@range, 1 ); #last arg is for reversal of order

      next unless @data;                      #should not be necessary

      $self->_annotateSugar(
        \@data,
        $allele,
        sub {
          my $posDataAref = shift;

          if ( $posDataAref && defined $posDataAref->[0] ) {
            #appending an undefined value doesn't affect output
            #if there isn't a hash, we should crash, means we don't understand
            #the spec / programmer error
            $reconstitutedAllele .= $posDataAref->[0]{ref_base};
          }
        }
      );

      if ($reconstitutedAllele) {
        $allele->renameMinorAllele($reconstitutedAllele);
        $reconstitutedAllele = '';
      }
    }
    else {
      #Our decision: current conceit is we consider the leading position
      #and the next position, in case we were at a boundary and disturbed the adjacent
      #feature
      @range = ( $abs_pos .. $abs_pos + 1 );
      @data = $db->db_bulk_get( \@range, 0 );

      next unless @data; #should not be necessary

      $self->_annotateSugar( \@data, $allele );
    }
  }
}

state $delim = '|';      #can't be ; or will get split, unless we prepend Type-Frame-
#Thomas, I noticed that we can potentially have many interesting variants
#Say indels that hit start and stop, so I want to grab them all, in order
#It seems like a waste not to if we're already 90% of the way there; people can
#ignore anything after the first delim if the wish to just see the most serious
sub _annotateSugar {
  my ( $self, $dataAref, $allele, $cb ) = @_;

  if ( !( $dataAref && @$dataAref && $allele ) ) {
    $self->log( 'warn', '_annotateSugar requires dataAref and allele' );
    return;
  }

  my $sugar;
  my $siteType = '';
  my $hasCoding = 0;
  my $frame    = '';
  # getSiteType defined in Seq::Site::Gene::Definitions Role
  # used to determine whether to call something FrameShift, InFrame, or no frame type
  state $codingName = $self->getSiteType(0); #for API: Coding type always first
  state $allowedSitesHref = { map { $_ => 1 } $self->allSiteTypes };

  for my $geneRecordAref (@$dataAref) {
    if ( !$geneRecordAref ) {
      $self->log( 'warn', 'Database may be malformed, 
        returned empty geneRecordAref, _annotateSugar' );
      next;
    }

    for my $transcriptHref (@$geneRecordAref) {
      if ( !$transcriptHref ) {
        $self->log('warn', 'Database may be malformed, 
          returned empty transcriptHref, _annotateSugar' );
        next;
      }

      $siteType = $transcriptHref->{site_type};
      next if !$allowedSitesHref->{$siteType};

      if ( defined $transcriptHref->{codon_number} ) { #we're in a coding region
        $hasCoding = 1 unless $hasCoding;
        if ( $transcriptHref->{codon_number} == 1 ) {
          #we do this to preserve order;hashes are pseudo-randomly sorted
          $sugar .= 'StartLoss|';
          
          # now check if we're in a stop, maybe we should just assume we have
          # a ref_aa_residue / not check defined?
        }
        elsif ( defined $transcriptHref->{ref_aa_residue}
        && $transcriptHref->{ref_aa_residue} eq '*' ) {
          $sugar .= 'StopLoss|';
        }
        else {
          $sugar .= $siteType.'|';
        }
      }
      else {
        $sugar .= $siteType.'|';
      }
    }
    if ($cb) { $cb->($geneRecordAref); }
  }

  chop $sugar;
  #frameshift only matters for coding regions; lookup in order of frequency
  $frame = $allele->frameType if $hasCoding;
  
  #the joiner is fasta's default separator; not using ; because that will split
  #when as_href called, and I don't want to have to concat Del-Frameshift
  #to each sugar key
  #note this will sometimes result in empty brackets. I think it makes sense
  #to keep those, becasue it makes parsing simpler, and contains information about feature absence
  $allele->set_annotation_type(
    $allele->typeName . ( $frame && "-$frame" ) . '[' . $sugar. ']' );
}

__PACKAGE__->meta->make_immutable;

1;