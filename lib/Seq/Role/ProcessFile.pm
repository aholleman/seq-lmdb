package Seq::Role::ProcessFile;
#TODO: when printing, also print out Types, whose index changes whether it's 
#v1 or v2
#and make it flexible enough to work with even snpfiles whose first 5-6 fields
#are out of order
our $VERSION = '0.001';

# ABSTRACT: A role for processing snp files
# VERSION

use 5.10.0;
use strict;
use warnings;

use Moose::Role;
use Moose::Util::TypeConstraints;
use File::Which qw(which);
use File::Basename;
use List::MoreUtils qw(firstidx);
use namespace::autoclean;
use DDP;
use List::Util qw /max/;

requires 'output_path';
requires 'out_file';
requires 'debug';

#requires get_write_bin_fh from Seq::Role::IO, can't formally requires it in a role
#requires log from Seq::Role::Message
with 'Seq::Role::IO', 'Seq::Role::Message',
#we expect other packages to build up the output header,
#then we consume it here
'Seq::Tracks::Headers';

# file_type defines the kind of file that is being annotated
#   - snp_1 => snpfile format: [ "Fragment", "Position", "Reference", "Minor_Allele"]
#   - snp_2 => snpfile format: ["Fragment", "Position", "Reference", "Alleles", "Allele_Counts", "Type"]
#   - vcf => placeholder
state $allowedTypes = [ 'snp_2', 'snp_1' ];
enum fileTypes => $allowedTypes;

# pre-define a file type; not necessary, but saves some time if type is snp_1
# @ public
has file_type => (
  is       => 'ro',
  isa      => 'fileTypes',
  required => 0,
  writer   => '_setFileType',
);

# @pseudo-protected; using _header to designate that only the methods are public
# stores everything after the minimum required; this comes from Seq::Annotate.pm
# add_header_attr called in Seq.pm
has _header => (
  traits  => ['Array'],
  is      => 'ro',
  isa     => 'ArrayRef',
  handles => {
    all_header_attr => 'elements',
    add_header_attr => 'push',
  },
  init_arg => undef,
  default => sub { [] },
);

# after add_header_attr => sub {
#   my $self = shift;

#   if ( !$self->_headerPrinted ) {
#     say { $self->_out_fh } join "\t", $self->all_header_attr;
#     $self->_flagHeaderPrinted;
#   }
# };

##########Private Variables##########

# flags whether or not the header has been printed
has _headerPrinted => (
  is      => 'rw',
  traits  => ['Bool'],
  isa     => 'Bool',
  default => 0,
  handles => { _flagHeaderPrinted => 'set', }, #set to 1
  init_arg => undef,
);

#if we compress the output, the extension we store it with
has _compressExtension => (
  is      => 'ro',
  lazy    => 1,
  default => '.tar.gz',
  init_arg => undef,
);

has _out_fh => (
  is       => 'ro',
  lazy     => 1,
  init_arg => undef,
  builder  => '_build_out_fh',
);

# the minimum required snp headers that we actually have
has _snpHeader => (
  traits => ['Array'],
  isa => 'ArrayRef',
  handles => {
    setSnpField => 'push',
    allSnpFieldIdx => 'elements',
  },
  init_arg => undef,
);

#all the header field names that we require;
#@ {HashRef[ArrayRef]} : file_type => [field1, field2...]
has _reqHeaderFields => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  init_arg => undef,
  builder => '_build_input_headers',
  handles => {
    allReqFields => 'get',
  },
);

#API: The order here is the order of values returend for any consuming programs
#See: $self->proc_line
sub _build_input_headers {
  return {
    snp_1 => [qw/ Fragment Position Reference Minor_allele Type /],
    snp_2 => [qw/ Fragment Position Reference Alleles Allele_Counts Type/],
  };
}

#only returning first four fields because we don't use allele_counts for anything
#at the moment
#normalize the names to newer format
sub getRequiredFileHeaderFieldNames {
  my $self = shift;
  return @{ $self->_reqHeaderFields->{$self->file_type} }[0 .. 4];
}

#takes an array of <HashRef> data that is what we grabbed from the database
#and whatever else we added to it
#and an array of <ArrayRef> input data, which contains our original input fields
#which we are going to re-use in our output (namely chr, position, type alleles)
sub makeAnnotationString {
  my ( $self, $outputDataAref, $inputDataAref ) = @_;

  # cache header attributes
  my ($headerKeysAref, $inputIdxAref) = $self->makeOutputHeader();

  #open(my $fh, '>', $filePath) or $self->log('fatal', "Couldn't open file $filePath for writing");
  # flatten entry hash references and print to file
  my $totalCount = 0;
  my $outStr;
  for my $href (@$outputDataAref) {
    #first map everything we want from the input file
    my @singleLineOutput = map { $inputDataAref->[$totalCount]->[$_] } @$inputIdxAref;
  
    $totalCount++;

    PARENT: for my $feature (@$headerKeysAref) {      
      if(ref $feature) {
        #it's a trackName => {feature1 => value1, ...}
        my ($parent) = %$feature;

        if(!defined $href->{$parent} ) {
          #https://ideone.com/v9ffO7
          push @singleLineOutput, map { 'NA' } @{ $feature->{$parent} };
          next PARENT;
        }

        CHILD: for my $child (@{ $feature->{$parent} } ) {
          if(!defined $href->{$parent}->{$child} ) {
            push @singleLineOutput, 'NA';
            next CHILD;
          }

          if(!ref $href->{$parent}{$child} ) {
            push @singleLineOutput, $href->{$parent}{$child};
            next CHILD;
          }

          if(ref $href->{$parent}{$child} ne 'ARRAY') {
            $self->log('warn', "Can\'t process non-array parent values, skipping $child");
            
            push @singleLineOutput, 'NA';
            next CHILD;
          }

          my $accum;
          ACCUM: foreach ( @{  $href->{$parent}{$child} } ) {
            if(!defined $_) {
              $accum .= 'NA;';
              next ACCUM;
            }
            $accum .= "$_;";
          }
          chop $accum;
          push @singleLineOutput, $accum;
        }
        next PARENT;
      }

      #say "feature is $feature";
      #p $href->{feature};
      if(!defined $href->{$feature} ) {
        push @singleLineOutput, 'NA';
        next PARENT;
      }

      if(!ref $href->{$feature} ) {
        push @singleLineOutput, $href->{$feature};
        next PARENT;
      }

      if(ref $href->{$feature} ne 'ARRAY') {
        # say "value for $feature is";
        # p $href->{$feature};
        # say 'ref is '. ref $href->{$feature};
        
          
        $self->log('warn', "Can\'t process non-array parent values, skipping $feature");
        push @singleLineOutput, 'NA';
        next PARENT;
      }

      my $accum;
      ACCUM: foreach ( @{ $href->{$feature} } ) {
        if(!defined $_) {
          $accum .= 'NA;';
          next ACCUM;
        }
        $accum .= "$_;";
      }
      chop $accum;
      push @singleLineOutput, $accum;
    }

    $outStr .= join("\t", @singleLineOutput) . "\n";
  }
  chop $outStr;
  return $outStr;
}

sub makeHeaderString {
  my $self = shift;

  my ($headersAref, $inputFieldIdxAref) = $self->makeOutputHeader();

  my @out = map { $self->_reqHeaderFields->{$self->file_type}->[$_] } @$inputFieldIdxAref;
  for my $feature (@$headersAref) {
    if(ref $feature) {
      my ($parentName) = %$feature;
      foreach (@{ $feature->{$parentName} } ) {
        push @out, "$parentName.$_";
      }
      next;
    }
    push @out, $feature;
  }
  #open (my $fh, '>', $filePath);
  return join("\t", @out);
}
#TODO: Set order of tracks based on order presented in configuration file
#we get
# {
#   parent => [child, child, child, child]
# }
sub makeOutputHeader {  
  state $trackHeadersAref;
  state $indexesFromInputAref;
  if(defined $trackHeadersAref) {
    return ($trackHeadersAref, $indexesFromInputAref);
  }

  my ($self, $additionalPrioritizedFieldsAref) = @_;

  my @trackHeaders = @$additionalPrioritizedFieldsAref;
  
  #Fragment Position Reference Type Minor_allele (Or Alleles which is newer name for Minor allele)
  $indexesFromInputAref = [0, 1, 3, 4];

  my $headerAref = $self->getOrderedTrackHeadersAref();

  for my $parent (@$headerAref) {
    if( ref $parent ) {
      my ($parentName) = %$parent;

      push @trackHeaders, { $parentName => [ keys %{ $parent->{$parentName} } ] };
      next;
    }
    push @trackHeaders, $parent;
  }

  $trackHeadersAref = \@trackHeaders;
  return ($trackHeadersAref, $indexesFromInputAref);
}

sub compress_output {
  my $self = shift;

  $self->log( 'info', 'Compressing all output files' );

  if ( !-e $self->output_path ) {
    return $self->log( 'warn', 'No output files to compress' );
  }

  # my($filename, $dirs) = fileparse($self->output_path);

  my $tar = which('tar') or $self->log( 'fatal', 'No tar program found' );
  my $pigz = which('pigz');
  if ($pigz) { $tar = "$tar --use-compress-program=$pigz"; } #-I $pigz

  my $baseFolderName = $self->out_file->parent->basename;
  my $baseFileName = $self->out_file->basename;
  my $compressName = $baseFileName . $self->_compressExtension;

  my $outcome =
    system(sprintf("$tar -cf %s -C %s %s --transform=s/%s/%s/ --exclude '.*' --exclude %s; mv %s %s",
      $compressName,
      $self->out_file->parent(2)->stringify, #change to parent of folder containing output files
      $baseFolderName, #the name of the directory we want to compress
      #transform and exclude
      $baseFolderName, #inside the tarball, transform  that directory name
      $baseFileName, #to one named as our file basename
      $compressName, #and don't include our new compressed file in our tarball
      #move our file into the original output directory
      $compressName,
      $self->out_file->parent->stringify,
    ) );
 
  $self->log( 'warn', "Zipping failed with $?" ) unless !$outcome;
}

sub checkHeader {
  my ( $self, $field_aref, $die_on_unknown ) = @_;

  $die_on_unknown = defined $die_on_unknown ? $die_on_unknown : 1;
  my $err;

  if($self->file_type) {
    $err = $self->_checkInvalid($field_aref, $self->file_type);
    $self->setHeader($field_aref);
  } else {
    for my $type (@$allowedTypes) {
      $err = $self->_checkInvalid($field_aref, $type);
      if(!$err) {
        $self->_setFileType($type);

        $self->setHeader($field_aref);
        last;
      }
    }
  }

  if($err) {
    $err = 'Provided input file doesn\'t match allowable types';
    if(defined $die_on_unknown) { 
      $self->log( 'fatal', $err); 
    }
    $self->log( 'warn', $err );
    return;
  }
  return 1;
}

# checks whether the first N fields, where N is the number of fields defined in
# $self->allReqFields, in the input file match the reqFields values
# order however in those first N fields doesn't matter
sub _checkInvalid {
  my ($self, $aRef, $type) = @_;

  my $reqFields = $self->allReqFields($type);

  my @inSlice = @$aRef[0 .. $#$reqFields];

  my $idx;
  for my $reqField (@$reqFields) {
    $idx = firstidx { $_ eq $reqField } @inSlice;
    if($idx == -1) {
      return "Input file header misformed. Coudln't find $reqField in first " 
        . @inSlice . ' fields.';
    }
  }
  return;
}

sub setHeader {
  my ($self, $aRef) = @_;

  my $idx;
  for my $field (@{$self->allReqFields($self->file_type) } ) {
    $idx = firstidx { $_ eq $field } @$aRef;
    $self->setSnpField($idx) unless $idx == -1;
  }
}

sub getSampleNamesIdx {
  my ($self, $fAref) = @_;
  my $strt = scalar @{$self->allReqFields($self->file_type) };

  # every other field column name is blank, holds genotype probability 
  # for preceeding column's sample;
  # don't just check for ne '', to avoid simple header issues
  my %data;

  for(my $i = $strt; $i <= $#$fAref; $i += 2) {
    $data{$fAref->[$i] } = $i;
  }
  return %data;
}

#presumes that _file_type exists and has corresponding key in _headerFields
#this can be called millions of times
#However, it seems unnecessary to put out here, added it back to the caller (Seq.pm)
# sub getSnpFields {
#   #my ( $self, $fieldsAref ) = @_;
#   #$_[0] == $self, $_[1 ] == $fieldAref

#   return map {$_[1]->[$_] } $_[0]->allSnpFieldIdx;
# }

=head2

B<_build_out_fh> - returns a filehandle and allow users to give us a directory or a
filepath, if directory use some sensible default

=cut

sub _build_out_fh {
  my $self = shift;

  if ( !$self->output_path ) {
    say "Did not find a file or directory path in Seq.pm _build_out_fh" if $self->debug;
    return \*STDOUT;
  }

  # can't use is_file or is_dir check before file made, unless it alraedy exists
  return $self->get_write_bin_fh( $self->output_path );
}

no Moose::Role;
1;
