Tracks
---
---
## Track Types

We expose 3 kinds of general purpose tracks
### General Tracks 

1. Sparse (sparse)
  - These are any tracks that have unique info per base
  - These must be .bed format with the following fields
    + chrom
    + chromStart
    + chromEnd
  - Ex: snp146

2. Score (score)
 - Any fixed wiggle format track
   + ex: PhyloP, PhastCons

3. Region (region) (not yet exposed)
  - Any region track
  - This can be used for cases where a single record spans more than one base
  - Example: RefSeq gene.
  - These must also be in .bed format with the following fields
    + chrom
    + chromStart
    + chromEnd

We also have several "private" track types. These are still defined in the config file, but are just our special implementations of the above 3.

### Special Tracks
These are special cases of the above tracks
1. Reference (1 MAX)
  - Accepts a multi-fasta file, stores the reference
  - There can only be one of these per database
  - It's really just a sparse track, but you can't have more than one reference

2. Gene
  - Stores a UCSC gene track. Ex: KnownGene, RefSeq Gene
  - It's just a region track, but one that downloads its data as UCSC .sql files (and then queries those)

3. CADD 
  - Any 3 column fixed wiggle format input file works for this

### TODO: 
1. Expose Region track
