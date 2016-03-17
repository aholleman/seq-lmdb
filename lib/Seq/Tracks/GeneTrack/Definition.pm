package Seq::Tracks::GeneTrack::Definition;
use 5.16.0;
use strict;
use warnings;

use Moose::Role 2;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

# Gene Tracks are a bit like cadd score tracks in that we need to match
# on allele
#We only need to konw these values; later everything is 
#The reason stuff other than chrom, txStart, txEnd are required is that we
#use cdsStart, cdsEnd, exonStarts exonEnds to determine whether we're in a 
#coding region, exon, etc
state $chr = 'chrom';
state $chrStart = 'txStart';
state $chrEnd = 'txEnd';
state $strand = 'strand';
state $cdsStart = 'cdsStart';
state $cdsEnd = 'cdsEnd';
state $exonStart = 'exonStarts';
state $exonEnd = 'exonEnds';

# state $reqFields = [$chr, $chrStart, $chrEnd, $strand, $cdsStart, $cdsEnd,
#   $exonStart, $exonEnd];
has chrField => (is => 'ro', lazy => 1, default => sub{$chr} );
has chrStartField => (is => 'ro', lazy => 1, default => sub{$chrStart} );
has chrEndField => (is => 'ro', lazy => 1, default => sub{$chrEnd} );
has strandField => (is => 'ro', lazy => 1, default => sub{$strand} );
has cdsStartField => (is => 'ro', lazy => 1, default => sub{$cdsStart} );
has cdsEndField => (is => 'ro', lazy => 1, default => sub{$cdsEnd} );
has exonStartField => (is => 'ro', lazy => 1, default => sub{$exonStart} );
has exonEndField => (is => 'ro', lazy => 1, default => sub{$exonEnd} );

enum requiredGeneTrackFields => [$chr, $chrStart, $chrEnd, $strand, $cdsStart,
 $cdsEnd, $exonStart, $exonEnd];

#old annotation_type
#has annotationType => 

no Moose::Role;
1;