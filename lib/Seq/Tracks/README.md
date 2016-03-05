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
1. Reference
  - Accepts a multi-fasta file, stores the reference
  - There can only be one of these per database
2. Gene
  - Stores a UCSC gene track. Ex: KnownGene, RefSeq Gene
  - There can only be one of these (but you could add more gene tracks as sparse or region)
3. NearestGene
  - A sparse track that stores a record of the nearest gene
  - There can only be one of these
4. Snp
  - A snp track (like dbSNP)

