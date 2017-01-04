# Seqant 2.0
## Annotator Output

Seqant outputs an incredible amount of data.

We recommend using the [Seqant web app](https://seqant.genetics.emory.edu) to annotate, because that automatically creates a Google-like search engine for your results, which makes filtering, sorting, etc much easier.

### Default Columns

1. chrom
	- The chromosome name

2. pos
	- The position. For deletions this is the first base deleted, for insertions this is the base just before the insertion.

3. type
	- The variant call. Possibilities: SNP, INS, DEL, MULTIALLELIC.
	- Seqant skips LOW (low confidence) or MESS (confusing) calls, which may be created by PECaller (does not apply to vcf annotation)
	- Seqant drops MULTIALLELIC calls from VCF files, because it uses Plink to convert the vcf file, and [Plink drops these sites (http://apol1.blogspot.com/2014/11/best-practice-for-converting-vcf-files.html)

4. etc

### How genome assemblies work

- A configuration file is required to build/update a database, or annotate
- It has several keys:
- *tracks*: What your database contains, and what you annotate against. Tracks have a name, which must be unique, and a type, which doesn't need to be unique
  - *type*: A track needs to have a type
    + *sparse*: Accepts any bed file, or any file that has at least a valid chrom, chromStart, and chromEnd. We can transform almost any file to fit this format, TODO: give example below.
    + *score*: Accepts any wigFix file. 
      + Used for phastCons, phyloP
    + *cadd*: Accepts any CADD file, or SeqAnt's custom "bed-like" CADD file (TODO: DESCRIBE)
      * CADD format: http://cadd.gs.washington.edu
    + *gene*: A UCSC gene track, either knownGene, or refGene. The "source files" for this is an `sql_statement` key assigned to this track (described below)

# TODO: FINISH

Each genome has features and steps enumerated for creating the needed data to
index and annotate it. Follow the keys and conventions in the example for genome
`hg38` to create a genome / annotation set yourself using the YAML format.

```
assembly: hg19
chromosomes:
  - chr1
  - chr2
  - chr3
  - chr4
  - chr5
  - chr6
  - chr7
  - chr8
  - chr9
  - chr10
  - chr11
  - chr12
  - chr13
  - chr14
  - chr15
  - chr16
  - chr17
  - chr18
  - chr19
  - chr20
  - chr21
  - chr22
  - chrM
  - chrX
  - chrY
database_dir: /home/akotlar/seqant_database/hg19/index_test/
files_dir: /ssd/seqant_db_build/hg19_snp142/raw/
output:
  order:
    - hg19
    - refSeq
    - snp146
    - clinvar
    - cadd
    - phastCons
    - phyloP
statistics:
  gene_track: refSeq
  snp_track: snp146
tracks:
  - 
    local_files:
      - /ssd/seqant_db_build/hg19_snp142/raw/hg19/chr1.fa.gz
      - chr2.fa.gz
      - chr3.fa.gz
      - chr4.fa.gz
      - chr5.fa.gz
      - chr6.fa.gz
      - chr7.fa.gz
      - chr8.fa.gz
      - chr9.fa.gz
      - chr10.fa.gz
      - chr11.fa.gz
      - chr12.fa.gz
      - chr13.fa.gz
      - chr14.fa.gz
      - chr15.fa.gz
      - chr16.fa.gz
      - chr17.fa.gz
      - chr18.fa.gz
      - chr19.fa.gz
      - chr20.fa.gz
      - chr21.fa.gz
      - chr22.fa.gz
      - chrM.fa.gz
      - chrX.fa.gz
      - chrY.fa.gz
    name: hg19
    remote_dir: http://hgdownload.soe.ucsc.edu/goldenPath/hg19/chromosomes/
    remote_files:
      - chr1.fa.gz
      - chr2.fa.gz
      - chr3.fa.gz
      - chr4.fa.gz
      - chr5.fa.gz
      - chr6.fa.gz
      - chr7.fa.gz
      - chr8.fa.gz
      - chr9.fa.gz
      - chr10.fa.gz
      - chr11.fa.gz
      - chr12.fa.gz
      - chr13.fa.gz
      - chr14.fa.gz
      - chr15.fa.gz
      - chr16.fa.gz
      - chr17.fa.gz
      - chr18.fa.gz
      - chr19.fa.gz
      - chr20.fa.gz
      - chr21.fa.gz
      - chr22.fa.gz
      - chrM.fa.gz
      - chrX.fa.gz
      - chrY.fa.gz
    type: reference
  - 
    features:
      - kgID
      - mRNA
      - spID
      - spDisplayID
      - geneSymbol
      - refseq
      - protAcc
      - description
      - rfamAcc
      - name
    local_files:
      - hg19.refGene.chr1.gz
      - hg19.refGene.chr2.gz
      - hg19.refGene.chr3.gz
      - hg19.refGene.chr4.gz
      - hg19.refGene.chr5.gz
      - hg19.refGene.chr6.gz
      - hg19.refGene.chr7.gz
      - hg19.refGene.chr8.gz
      - hg19.refGene.chr9.gz
      - hg19.refGene.chr10.gz
      - hg19.refGene.chr11.gz
      - hg19.refGene.chr12.gz
      - hg19.refGene.chr13.gz
      - hg19.refGene.chr14.gz
      - hg19.refGene.chr15.gz
      - hg19.refGene.chr16.gz
      - hg19.refGene.chr17.gz
      - hg19.refGene.chr18.gz
      - hg19.refGene.chr19.gz
      - hg19.refGene.chr20.gz
      - hg19.refGene.chr21.gz
      - hg19.refGene.chr22.gz
      - hg19.refGene.chrX.gz
      - hg19.refGene.chrY.gz
    name: refSeq
    nearest:
      - name
      - geneSymbol
    join:
      track: clinvar
      features:
        - PhenotypeIDs
        - OtherIDs
    sql_statement: 'SELECT * FROM hg19.refGene LEFT JOIN hg19.kgXref ON hg19.kgXref.refseq
      = hg19.refGene.name'
    type: gene
  - 
    local_files:
      - chr1.phastCons100way.wigFix.gz
      - chr2.phastCons100way.wigFix.gz
      - chr3.phastCons100way.wigFix.gz
      - chr4.phastCons100way.wigFix.gz
      - chr5.phastCons100way.wigFix.gz
      - chr6.phastCons100way.wigFix.gz
      - chr7.phastCons100way.wigFix.gz
      - chr8.phastCons100way.wigFix.gz
      - chr9.phastCons100way.wigFix.gz
      - chr10.phastCons100way.wigFix.gz
      - chr11.phastCons100way.wigFix.gz
      - chr12.phastCons100way.wigFix.gz
      - chr13.phastCons100way.wigFix.gz
      - chr14.phastCons100way.wigFix.gz
      - chr15.phastCons100way.wigFix.gz
      - chr16.phastCons100way.wigFix.gz
      - chr17.phastCons100way.wigFix.gz
      - chr18.phastCons100way.wigFix.gz
      - chr19.phastCons100way.wigFix.gz
      - chr20.phastCons100way.wigFix.gz
      - chr21.phastCons100way.wigFix.gz
      - chr22.phastCons100way.wigFix.gz
      - chrX.phastCons100way.wigFix.gz
      - chrY.phastCons100way.wigFix.gz
      - chrM.phastCons100way.wigFix.gz
    name: phastCons
    remote_dir: http://hgdownload.soe.ucsc.edu/goldenPath/hg19/phastCons100way/hg19.100way.phastCons/
    remote_files:
      - chr1.phastCons100way.wigFix.gz
      - chr2.phastCons100way.wigFix.gz
      - chr3.phastCons100way.wigFix.gz
      - chr4.phastCons100way.wigFix.gz
      - chr5.phastCons100way.wigFix.gz
      - chr6.phastCons100way.wigFix.gz
      - chr7.phastCons100way.wigFix.gz
      - chr8.phastCons100way.wigFix.gz
      - chr9.phastCons100way.wigFix.gz
      - chr10.phastCons100way.wigFix.gz
      - chr11.phastCons100way.wigFix.gz
      - chr12.phastCons100way.wigFix.gz
      - chr13.phastCons100way.wigFix.gz
      - chr14.phastCons100way.wigFix.gz
      - chr15.phastCons100way.wigFix.gz
      - chr16.phastCons100way.wigFix.gz
      - chr17.phastCons100way.wigFix.gz
      - chr18.phastCons100way.wigFix.gz
      - chr19.phastCons100way.wigFix.gz
      - chr20.phastCons100way.wigFix.gz
      - chr21.phastCons100way.wigFix.gz
      - chr22.phastCons100way.wigFix.gz
      - chrX.phastCons100way.wigFix.gz
      - chrY.phastCons100way.wigFix.gz
      - chrM.phastCons100way.wigFix.gz
    type: score
  - 
    local_files:
      - chr1.phyloP100way.wigFix.gz
      - chr2.phyloP100way.wigFix.gz
      - chr3.phyloP100way.wigFix.gz
      - chr4.phyloP100way.wigFix.gz
      - chr5.phyloP100way.wigFix.gz
      - chr6.phyloP100way.wigFix.gz
      - chr7.phyloP100way.wigFix.gz
      - chr8.phyloP100way.wigFix.gz
      - chr9.phyloP100way.wigFix.gz
      - chr10.phyloP100way.wigFix.gz
      - chr11.phyloP100way.wigFix.gz
      - chr12.phyloP100way.wigFix.gz
      - chr13.phyloP100way.wigFix.gz
      - chr14.phyloP100way.wigFix.gz
      - chr15.phyloP100way.wigFix.gz
      - chr16.phyloP100way.wigFix.gz
      - chr17.phyloP100way.wigFix.gz
      - chr18.phyloP100way.wigFix.gz
      - chr19.phyloP100way.wigFix.gz
      - chr20.phyloP100way.wigFix.gz
      - chr21.phyloP100way.wigFix.gz
      - chr22.phyloP100way.wigFix.gz
      - chrX.phyloP100way.wigFix.gz
      - chrY.phyloP100way.wigFix.gz
      - chrM.phyloP100way.wigFix.gz
    name: phyloP
    remote_dir: http://hgdownload.soe.ucsc.edu/goldenPath/hg19/phyloP100way/hg19.100way.phyloP100way/
    remote_files:
      - chr1.phyloP100way.wigFix.gz
      - chr2.phyloP100way.wigFix.gz
      - chr3.phyloP100way.wigFix.gz
      - chr4.phyloP100way.wigFix.gz
      - chr5.phyloP100way.wigFix.gz
      - chr6.phyloP100way.wigFix.gz
      - chr7.phyloP100way.wigFix.gz
      - chr8.phyloP100way.wigFix.gz
      - chr9.phyloP100way.wigFix.gz
      - chr10.phyloP100way.wigFix.gz
      - chr11.phyloP100way.wigFix.gz
      - chr12.phyloP100way.wigFix.gz
      - chr13.phyloP100way.wigFix.gz
      - chr14.phyloP100way.wigFix.gz
      - chr15.phyloP100way.wigFix.gz
      - chr16.phyloP100way.wigFix.gz
      - chr17.phyloP100way.wigFix.gz
      - chr18.phyloP100way.wigFix.gz
      - chr19.phyloP100way.wigFix.gz
      - chr20.phyloP100way.wigFix.gz
      - chr21.phyloP100way.wigFix.gz
      - chr22.phyloP100way.wigFix.gz
      - chrX.phyloP100way.wigFix.gz
      - chrY.phyloP100way.wigFix.gz
      - chrM.phyloP100way.wigFix.gz
    type: score
  - 
    local_files:
      - whole_genome_SNVs.tsv.chr1.bed.gz.bak
    name: cadd
    type: cadd
  - 
    features:
      - name
      - strand
      - observed
      - class
      - func
      - alleles
      - alleleNs: int
      - alleleFreqs: float
    multi_delim: ","
    local_files:
      - hg19.snp146.chr1.gz
      - hg19.snp146.chr2.gz
      - hg19.snp146.chr3.gz
      - hg19.snp146.chr4.gz
      - hg19.snp146.chr5.gz
      - hg19.snp146.chr6.gz
      - hg19.snp146.chr7.gz
      - hg19.snp146.chr8.gz
      - hg19.snp146.chr9.gz
      - hg19.snp146.chr10.gz
      - hg19.snp146.chr11.gz
      - hg19.snp146.chr12.gz
      - hg19.snp146.chr13.gz
      - hg19.snp146.chr14.gz
      - hg19.snp146.chr15.gz
      - hg19.snp146.chr16.gz
      - hg19.snp146.chr17.gz
      - hg19.snp146.chr18.gz
      - hg19.snp146.chr19.gz
      - hg19.snp146.chr20.gz
      - hg19.snp146.chr21.gz
      - hg19.snp146.chr22.gz
      - hg19.snp146.chrM.gz
      - hg19.snp146.chrX.gz
      - hg19.snp146.chrY.gz
    name: snp146
    sql_statement: SELECT * FROM hg19.snp146
    type: sparse
  - 
    build_field_transformations:
      Chromosome: chr .
      PhenotypeIDs: "split [;,]"
      OtherIDs: "split [;,]"
    build_row_filters:
      Assembly: == GRCh37
    features:
      - ClinicalSignificance
      - Type
      - Origin
      - ReviewStatus
      - OtherIDs
      - ReferenceAllele
      - AlternateAllele
      - PhenotypeIDs
    local_files:
      - variant_summary.txt
    name: clinvar
    required_fields_map:
      chrom: Chromosome
      chromStart: Start
      chromEnd: Stop
    type: sparse
    split: "split ;"
```

# Directories and Files

1. `files_dir` : Where our source files are located (optional). If provided, will be used to figure out where relative path local_files are

Ex:
```
files_dir: /ssd/seqant_db_build/hg19_snp142/raw/
tracks:
- 
  name: hg19
  local_files:
    - /ssd/seqant_db_build/hg19_snp142/raw/hg19/chr1.fa.gz
    - chr2.fa.gz
    - chr3.fa.gz
```

In this instance, the first local_file is absolute, and will be left as is.
The 2nd local file is relative, and so Seqant will interpret it's location as being found at 
`files_dir`/`name`/`local_files[1]` which, based on the values of those entries is: `ssd/seqant_db_build/hg19_snp142/raw/hg19/chr2.fa.gz`

2. `database_dir` : Where the database is located. Required.

Note that local_files may be globs
Ex:
```
local_files:
    - /ssd/seqant_db_build/hg19_snp142/raw/hg19/chr*
```
Will find all files beginning with chr in that directory (relative path globs also accepted, i.e `chr*`, provided that files_dir is provided)

# setup

1. SeqAnt requires the [LMDB](http://search.cpan.org/dist/LMDB_File/lib/LMDB_File.pm) DBM, TODO: IMPLEMENT INSTRUCTIONS

2. Install the SeqAnt Perl package.

To install the dependencies:

    ack --perl "use " | perl -nlE \
		'{ if ($_ =~ m/\:use ([\w\d.:]+)/) { $modules{$1}++; }}
		END{ print join "\n", sort keys %modules; }' | grep -v Seq

Install required linux packages (shown for CentOS/Fedora)
```
sudo yum install zlib-devel
```

Install dependencies with `cpan` like so:

```
cpan install Moose
cpan install MooseX::Types::Path::Tiny
cpan install DDP
cpan install YAML::XS
cpan install Getopt::Long::Descriptive
cpan install MCE::Loop
cpan install List::MoreUtils::XS
cpan install Data::MessagePack
cpan install Alien::LMDB
cpan install LMDB_File
cpan install Sort::XS
cpan install Hash::Merge::Simple
cpan install Log::Fast
cpan install Cpanel::JSON::XS
cpan install PerlIO::utf8_strict
cpan install PerlIO::gzip
cpan install Type::Params
cpan install MooseX::Getopt
cpan install MooseX::Getopt::Usage
cpan install forks
```

# Advanced
If you want to deploy the redis queue server:
```
sudo yum install git 
git clone git@github.com:redis/hiredis.git
cd hiredis
make
sudo make install

cpan install Redis::hiredis
```

If you want to fetch remote files (Utils::Fetch):
```
cpan install DBI
cpan install DBD::mysql
```
3. SeqAnt comes with a number of pre-specified genome assemblies in the `./config` 
directory.

# build a complete annotation assembly

We are assuming the data is fetched and in the directories that are specified by
the configuration file.

The following will build all databases sequentially.

		./bin/build_genome_assembly.pl --config hg38.yml --type transcript_db
		./bin/build_genome_assembly.pl --config hg38.yml --type snp_db
		./bin/build_genome_assembly.pl --config hg38.yml --type gene_db
		./bin/build_genome_assembly.pl --config hg38.yml --type genome --hasher ./bin/genome_hasher

The following approach will generate shell scripts to allow parallel building.

		# write scripts to build the gene and snp dbs
		./bin/run_all_build.pl -b ./bin/build_genome_assembly.pl -c ./ex/hg38_c_mdb.yml

		# build the transcript db
		./bin/build_genome_assembly.pl --config ./config/hg38_c_mdb.yml --type transcript_db

		# build conserv score tracks
		./bin/build_genome_assembly.pl --config ./config/hg38_c_mdb.yml --type conserv

		# build genome index
		./bin/build_genome_assembly.pl --config ./config/hg38_c_mdb.yml --type genome

TODO: add information about how to build CADD scores.

# adding customized Snp Tracks to an assembly

While either the GeneTrack or SnpTrack could be used to add sparse genomic data
to an assembly, it is most straightforward to add sparse data as a SnpTrack. The
procedure is to prepare a tab-delimited file with the desired data that follows
an extended bed file format (described below); define the features you wish
to include as annotations in the configuration file; and, run the builder script
twice - first to create the track data and second to build the binary genome
that is aware of your custom track.

1. prepare a tab-delimited file

The essential columns are: `chrom chromStart chromEnd name`. These are the same
columns as a 4-column bed file. There is no requirement that those columns be in
any particular order or that they are the only columns in the file. The only
essential thing is that they are present and named in the header _exactly_ as
described above. Additional information to be included as part of the annotation
should be in separate labeled columns. You must specify which columns to include
in the genome assembly configuration file and columns that are not specified
will be ignored.

2. add the SnpTrack data to the configuration file. For example,

		- type: snp
			local_dir: /path/to/file
			local_file: hg38.neuro_mutdb.txt
			name: neurodb
			features:
				- name
				- exon_name
				- site
				- ref

The features are names of columns with data to be added to the annotation of the
site. Only columns with this data will be saved, and an error will be generated
if there is no column with a specified name.

3. run the builder script to build the database

You will need to, at least, make the annotation database, and to be safe, you
should remake the encoded binary genome files to update the locations of known
SNPs. The following example supposes that you only have data on chromosome 5 and
that you are adding to an existing assembly.

		# create new database
		build_genome_assembly.pl --config hg38_c_mdb.yml --type snp_db --wanted_chr chr5

		# create genome index
		build_genome_assembly.pl --config hg38_c_mdb.yml --type genome --verbose --hasher ./bin/genome_hasher


