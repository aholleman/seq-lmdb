Tracks
---
---
## Track Types

We expose 3 kinds of general purpose tracks

1. SparseTrack (sparse)
  - These are any tracks that have unique info per base
  - These must be .bed format with the following fields
    + chrom
    + chromStart
    + chromEnd

2. RegionTrack (region)
  - Any region track
  - This can be used for cases where a single record spans more than one base
  - Example: RefSeq gene.
  - These must also be in .bed format with the following fields
    + chrom
    + chromStart
    + chromEnd

3. ScoreTrack (score)
 - Any wiggle format track
   + ex: CADD, PhyloP, PhastCons
   + we accept 1 column or 3 columns per position
   + 3 is used in case that the format gives a score for each possible base (like CADD)

We also have several "private" track types. These are still defined in the config file, but are just our special implementations of the above 3.

### Special Tracks 
These are special cases of the above tracks #1 and 2
1. Reference
  - Accepts a multi-fasta file, stores the reference
  - There can only be one of these per database
  - It's really just a sparse track, but you can't have more than one reference
2. Gene
  - Stores a UCSC gene track. Ex: KnownGene, RefSeq Gene
  - It's just a region track, but one that downloads its data as UCSC .sql files (and then queries those)
3. Snp
  - A USCSC snp track (like dbSNP)
  - It's just a sparse track, but we have a few custom actions attached

