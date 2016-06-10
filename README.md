Seq
---
---
## How genome assemblies work

- These are specified in a YAML file.
- The assembly has some basic features, e.g., name, description, chromosomes,
and information about the mongo instance for storing some of the track
information.
  - *reference tracks*: Any multi-fasta file containin assembly info.
	- *sparse tracks*: Accepts any bed file.
	- *score tracks*: Accepts any wigFix file. 
    - Used for phastCons, phyloP
  - *cadd tracks*: Accepts any CADD file. 
    - CADD uses a completely non-standard input file. We also accept a 3 column wigFix file that does not have a header. Where each column corresponds to the alphabetically-ordered alternative alleles
      - Ex: if ref is T: A C G
      - Ex: if ref is A: C G T    
  - *gene tracks*: This is a specific kind of region track, which accepts either UCSC knownGenes or refSeq gene .sql files.
  - *region tracks*: Accepts any bed file. Is like a sparse track, but more space-efficient when many lines in the track cover more than one base
	annotations that cover a substantial portion of the genome.


Each genome has features and steps enumerated for creating the needed data to
index and annotate it. Follow the keys and conventions in the example for genome
`hg38` to create a genome / annotation set yourself using the YAML format.

```
---
genome_name: hg38
genome_description: human
genome_chrs:
  - chr1
genome_index_dir: ./hg38/index
host: 127.0.0.1
port: 27107

# sparse tracks
sparse_tracks:
  - type: gene
    local_dir: ./hg38/raw/gene
    local_file: knownGene.txt.gz
    name: knownGene
    sql_statement: SELECT _gene_fields FROM hg38.knownGene LEFT JOIN hg38.kgXref ON hg38.kgXref.kgID = hg38.knownGene.name

# for gene sparse tracks the 'features' key holds extra names the gene may
# be called
    features:
      - mRNA
      - spID
      - spDisplayID
      - geneSymbol
      - refseq
      - protAcc
      - description
      - rfamAcc
  - type: snp
    local_dir: ./hg38/raw/snp/
    local_file: snp141.txt.gz
    name: snp141
    sql_statement: SELECT _snp_fields FROM hg38.snp141

# for snp sparse tracks the 'features' key holds extra annotation
# information
    features:
      - alleles
      - maf
genome_sized_tracks:
  - name: hg38
    type: genome
    local_dir: ./hg38/raw/seq/
    local_files:
      - chr1.fa.gz
    remote_dir: hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/
    remote_files:
      - chr1.fa.gz
  - name: phastCons
    type: score
    local_dir: ./hg38/raw/phastCons
    local_files:
      - phastCons.txt.gz
    remote_dir: hgdownload.soe.ucsc.edu/goldenPath/hg38/phastCons7way/
    remote_files:
      - hg38.phastCons7way.wigFix.gz
    proc_init_cmds:
      - split_wigFix.py _asterisk.wigFix.gz
    proc_chrs_cmds:
      - create_cons.py _chr _dir
      - cat _chr._dir _add_file _dir.txt
      - rm _chr._dir
      - rm _chr
    proc_clean_cmds:
      - gzip phastCons.txt
  - name: phyloP
    type: score
    local_dir: ./hg38/raw/phyloP
    local_files:
      - phyloP.txt.gz
    remote_dir: hgdownload.soe.ucsc.edu/goldenPath/hg38/phyloP7way/
    remote_files:
      - hg38.phyloP7way.wigFix.gz
    proc_init_cmds:
      - split_wigFix.py _asterisk.wigFix.gz
    proc_chrs_cmds:
      - create_cons.py _chr _dir
      - cat _chr._dir _add_file _dir.txt
      - rm _chr._dir
      - rm _chr
    proc_clean_cmds:
      - gzip phyloP.txt
```

# directory structure

The main genome directories are organized like so (and specified in the
configuration file):
1. `genome_raw_dir` directory unsurprisingly holds all raw data (or will hold 
    after it is fetched). It is organized as follows:
    - `genome` directory holds the fasta files for the organism genome.
    - `gene` directory holds coordinates for gene.
    - `score` directory hold conservation scores (phyloP, cadd, etc).
    - `snp` directory holds snp data.
    - Each directory corresponds to a `type` of data specified in the 
    configuration file for the genome assembly.

2. `genome_index_dir` directory holds all of the files of the assembly after
    they are written. There are no sub-directories.

# setup

1. SeqAnt requires the [Kyoto Cabinet](http://fallabs.com/kyotocabinet/) DBM, and
you will need to install the core library and the Perl package.
  - Download the latest [C/C++ core library](http://fallabs.com/kyotocabinet/pkg/).
  - Download the latest [Perl package](http://fallabs.com/kyotocabinet/perlpkg/).
  - Both of these will need to be installed for SeqAnt to work properly.

2. Install the SeqAnt Perl package.
  - Right now, you'll have to build the 3 c programs and run the scripts from 
  within the package directory. This will change once we package into one tarball.

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


