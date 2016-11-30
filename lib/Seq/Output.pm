package Seq::Output;
use 5.10.0;
use strict;
use warnings;

use Mouse 2;
use Search::Elasticsearch;
# use Search::Elasticsearch::Async;
use Scalar::Util qw/looks_like_number/;

use Seq::Output::Delimiters;
use Seq::Headers;

with 'Seq::Role::Message';

use DDP;

has outputDataFields => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => sub { [] },
  writer => 'setOutputDataFieldsWanted',
);

has delimiters => (is => 'ro', isa => 'Seq::Output::Delimiters', default => sub {
  return Seq::Output::Delimiters->new();
});

sub BUILD {
  my $self = shift;

  $self->{_headers} = Seq::Headers->new();
  # my $delimiters = Seq::Output::Delimiters->new();

  # To try to avoid accessor penalty; 
  # These may be called hundreds of millions of times
  # $self->{_primaryDelimiter} = $self->delimiters->primaryDelimiter;
  # $self->{_secondaryDelimiter} = $self->delimiters->secondaryDelimiter;
  # $self->{_fieldSeparator} = $self->delimiters->fieldSeparator;
  # $self->{_emptyFieldChar} = $self->delimiters->emptyFieldChar;
  
}

# ABSTRACT: Knows how to make an output string
# VERSION

#takes an array of <HashRef> data that is what we grabbed from the database
#and whatever else we added to it
#and an array of <ArrayRef> input data, which contains our original input fields
#which we are going to re-use in our output (namely chr, position, type alleles)
sub makeOutputString {
  my ($self, $outputDataAref) = @_;
  # my $fieldSeparator = $self->{_fieldSeparator};
  my $emptyFieldChar = $self->delimiters->emptyFieldChar;

  my $rowIdx;

  my $alleleDelimiter = $self->delimiters->alleleDelimiter;
  my $positionDelimiter = $self->delimiters->positionDelimiter;
  my $valueDelimiter = $self->delimiters->valueDelimiter;
  my $fieldSeparator = $self->delimiters->fieldSeparator;

  if(!$self->{_multiDepth}) {
    my @headers = @{ $self->{_headers}->getOrderedHeaderNoMap() };

    $self->{_multiDepth} = { map {
      $_ => ref $headers[$_] ? 3 : 2;
    } 0 .. $#headers };

    $self->{_orderedHeader} = \@headers;
  }
  # p @{$self->{_orderedHeader}};
  my $trackIdx = -1;
  my $multiallelic;
  my $featureData;
  for my $row (@$outputDataAref) {
    $rowIdx = 0;

    # if($row->[2][0][0] eq 'MULTIALLELIC') {
    #   p $row;
    # }
    # p $row;
    $trackIdx = 0;
    TRACK_LOOP: for my $trackName ( @{$self->{_orderedHeader}} ) {
      if(ref $trackName) {
        if(!defined $row->[$trackIdx]) {
          $row->[$trackIdx] = join($fieldSeparator, ($emptyFieldChar) x @$trackName);

          $trackIdx++;
          next TRACK_LOOP;
        }

        for my $featureIdx (0 .. $#$trackName) {
          $featureData = $row->[$trackIdx][$featureIdx];

          # p $featureData;
          for my $alleleData (@{$row->[$trackIdx][$featureIdx]}) {
            # p $alleleData;
            for my $positionData (@$alleleData) {
              $positionData //= $emptyFieldChar;

              if(ref $positionData) {
                $positionData = join($valueDelimiter, map { 
                  $_
                  # Unfortunately, prior to 11/30/16 Seqant dbs would merge sparse tracks
                  # incorrectly, resulting in an extra array depth
                  ? (ref $_ ? join($valueDelimiter, map { $_ || $emptyFieldChar } @$_) : $_)
                  : $emptyFieldChar
                } @$positionData);
              }

              # p $positionData;
            }
            $alleleData = @$alleleData > 1 ? join($positionDelimiter, @$alleleData) : $alleleData->[0];
          }

          # p $featureData;

          $row->[$trackIdx][$featureIdx] =
            @{$row->[$trackIdx][$featureIdx]} > 1 
            ? join($alleleDelimiter, @$featureData)
            : $row->[$trackIdx][$featureIdx][0];

          # p $featureData;
        }

        # if($)
        # p $row->[$trackIdx];
        # $row->[$trackIdx] =
        #   @{$row->[$trackIdx]} > 1 
        #   ? join($alleleDelimiter, @%{$row->[$trackIdx]})
        #   : $row->[$trackIdx][0]
        $row->[$trackIdx] = join($fieldSeparator, @{$row->[$trackIdx]});

        # p $row->[$trackIdx];
      } else {
        if(!defined $row->[$trackIdx]) {
          # say "$trackIdx not defined";

          $row->[$trackIdx] = $emptyFieldChar;

          $trackIdx++;
          next TRACK_LOOP;
        }

        # p $featureData;
        # p $row->[$trackIdx];
        for my $alleleData (@{$row->[$trackIdx]}) {
          # p $alleleData;
          if(!$alleleData) {
            # p $row;
          }
          for my $positionData (@$alleleData) {
            $positionData //= $emptyFieldChar;

            if(ref $positionData) {
              $positionData = join($valueDelimiter, map { $_ || $emptyFieldChar } @$positionData);
            }

            # p $positionData;
          }
          $alleleData = @$alleleData > 1 ? join($positionDelimiter, @$alleleData) : $alleleData->[0];

          # p $alleleData;
        }

        $row->[$trackIdx] = join($alleleDelimiter, @{$row->[$trackIdx]});

      }

      $trackIdx++;
    }
    
    $row = join("\t", @$row);
  }

  return join("\n", @$outputDataAref) . "\n";
}
  # for my $row (@$outputDataAref) {
  #   $rowIdx = 0;

  #   if($row->[2] eq 'MULTIALLELIC') {
  #     p $row;
  #   }

  #   $trackIdx = -1;
  #   $multiallelic = 0;
  #   TRACK_LOOP: for my $trackName ( @{$self->{_orderedHeader}} ) {
  #     $trackIdx++;

  #     if(ref $trackName) {
  #       if(!$row->[$trackIdx]) {
  #         $row->[$trackIdx] = join("\t", ($emptyFieldChar) x @$trackName);
  #         next TRACK_LOOP;
  #       }

  #       # p $row->[$trackIdx];
  #       # It's a track that has child features
  #       FEATURE_LOOP: for my $featureIdx (0 .. $#$trackName) {
  #         if(!$row->[$trackIdx][$featureIdx]) {
  #           $row->[$trackIdx][$featureIdx] = $emptyFieldChar;
  #           next FEATURE_LOOP;
  #         }

  #         # It's a 1D or 3D array
  #         if(ref $row->[$trackIdx][$featureIdx]) {
  #           ALLELE_LOOP: for my $alleleData ( @{$row->[$trackIdx][$featureIdx]} ) {
  #             if(!$alleleData) {
  #               $alleleData = $emptyFieldChar;
  #               next ALLELE_LOOP;
  #             }

  #             if(ref $alleleData) {
  #               $alleleData = join(';', map {
  #                 # In the revision of the dbs prior to 11/29/16
  #                 # sparse tracks that were merged contained fields that were arrays of arrays
  #                 # instead of 1D arrays 
  #                 $_ ? (ref $_ ? join(';', map{ $_ || $emptyFieldChar } @{$_}) : $_ ) : $emptyFieldChar
  #               } @$alleleData);

  #               p $alleleData;
  #             }
  #           }
  #         }

  #       }

  #       next TRACK_LOOP;
  #     }

  #     # some tracks may have no data, replace with empty field character
  #     if(!$row->[$trackIdx]) {
  #       $row->[$trackIdx] = $emptyFieldChar;
  #       next TRACK_LOOP;
  #     }
  #   }
  # }
    # $trackIdx = -1;
    # TRACK_LOOP: for my $track (@$row) {
    #   $trackIdx++;

    #   # some tracks may have no data, replace with empty field character
    #   $track //= $emptyFieldChar;

    #   # We can have two modes... Either a 3 deep array, or a 1 deep array
    #   # 0-1 deep is used by single allele, single position variants
    #   # 3 deep for everything else
    #   if(!ref $track) {
    #     next TRACK_LOOP;
    #   }

    #   # If it's an array ref it could be a 1D array-based track feature,
    #   # or a 3D array (minimum, due to Seqant db merge bug could be 4 deep, see below)
    #   # If a different kind of reference, this will crash hard, reflecting a serious 
    #   # misunderstanding of how getters should function
    #   for my $alleleOrFeature (@$track) {
    #     $alleleOrFeature //= $emptyFieldChar;

    #     # p $alleleOrFeature;
    #     # Found an inner array. It's a 3D (minimum) array
    #     if(ref $alleleOrFeature) {
    #       for my $positionData (@$alleleOrFeature) {
    #         # some entries may be undef, cannot join these
    #         $positionData //= $emptyFieldChar;

    #         if($self->{_multiDepth}{$trackIdx} == 3) {
    #           if(ref $positionData) {
    #             for my $featureVal (@$positionData) {
    #               # p $featureVal;
    #             }
                
    #             p $row;
    #             $self->log('fatal', "Expected either 1 or 3+ deep array, got 2");
    #             return;
    #           }

    #           # Inside each position should be feature data
    #           # Unfortunately, one build of Seqant did not properly merge
    #           # sparse tracks, resulting in an extra deep array
    #           # So we have this extra inner merge step
    #           # $positionData = join(';', map {
    #           #   $_ ? (ref $_ ? join(';', map { $_ || $emptyFieldChar } @{$_}) : $_) : $emptyFieldChar
    #           # } @$positionData);
    #         }
    #       }

    #       # It's an allele, join those by \
    #       $alleleOrFeature = join('/', @$alleleOrFeature);

    #       # If we don't move on, then the outer track data will get ';' delimited
    #       next TRACK_LOOP;
    #     }

    #     # if($self->{_multiDepth}[$trackIdx] == 2) {
    #     #   p $track;
    #     #   p $row;
    #     #   $self->log('fatal', "Expected either 1 or 3+ deep array, got 2");
    #     #   return;
    #     # }
    #   }

    #   # The track data is a reference, but it's a 1D array, join that by ";"
    #   $track = join(';', @$track)
    # }

  #   $row = join("\t", @$row);
  # }

  # p @$outputDataAref;

  # return join("\n", @$outputDataAref) . "\n";
#}
# sub makeOutputString {
#   my ( $self, $outputDataAref) = @_;

#   #open(my $fh, '>', $filePath) or $self->log('fatal', "Couldn't open file $filePath for writing");
#   # flatten entry hash references and print to file
#   my $outStr = '';
#   my $count = 1;

#   my $primaryDelim = $self->{_primaryDelimiter};
#   my $secondDelim = $self->{_secondaryDelimiter};
#   my $fieldSeparator = $self->{_fieldSeparator};
#   my $emptyFieldChar = $self->{_emptyFieldChar};

#   for my $href (@$outputDataAref) {
#     my @singleLineOutput;
    
#     PARENT: for my $feature ( @{$self->outputDataFields} ) {
#       if(ref $feature) {
#         #it's a trackName => {feature1 => value1, ...}
#         my ($parent) = %$feature;

#         if(!defined $href->{$parent} ) {
#           #https://ideone.com/v9ffO7
#           push @singleLineOutput, map { $emptyFieldChar } @{ $feature->{$parent} };
#           next PARENT;
#         }

#         if(!ref $href->{$parent}) {
#           push @singleLineOutput, $href->{$parent};
#           next PARENT;
#         }
        
#         CHILD: for my $child (@{ $feature->{$parent} } ) {
#           if(ref $href->{$parent} && ref $href->{$parent} ne 'HASH') {
#             say "NOT A HASH REF";
#             p $href;
#             p $parent;
#             p $child;

#             p $href->{$parent};
            
#           }
          
#           if(!defined $href->{$parent}{$child} ) {
#             push @singleLineOutput, $emptyFieldChar;
#             next CHILD;
#           }

#           if(!ref $href->{$parent}{$child} ) {
#             push @singleLineOutput, $href->{$parent}{$child};
#             next CHILD;
#           }

#           # if(ref $href->{$parent}{$child} eq 'HASH') {
#           #   push @singleLineOutput, $href->{$parent}{$child};
#           #   next CHILD;
#           # }

#           # Empty array
#           if( !@{ $href->{$parent}{$child} } ) {
#             push @singleLineOutput, $emptyFieldChar;
#             next PARENT;
#           }

#           # if( @{ $href->{$parent}{$child} } == 1 && !ref $href->{$parent}{$child}[0] ) {
#           #   push @singleLineOutput, defined $href->{$parent}{$child}[0] ? $href->{$parent}{$child}[0] : 'NA';

  

#           #   next PARENT;
#           # }


#           my $accum = '';
#           ACCUM: foreach ( @{ $href->{$parent}{$child} } ) {
#             if(!defined $_) {
#               $accum .= "$emptyFieldChar$primaryDelim";
#               next ACCUM;
#             }
#             # we could have an array of arrays, separate those by commas
#             if(ref $_) {
#               for my $val (@{$_}) {
#                 $accum .= defined $val ? "$val$primaryDelim" : "$emptyFieldChar$primaryDelim";
#               }
#               chop $accum;
#               $accum .= $secondDelim;
#               next ACCUM;
#             }

#             $accum .= "$_$primaryDelim";
#           }

#           chop $accum;
#           push @singleLineOutput, $accum;
#         }
#         next PARENT;
#       }

#       ### This could be split into separate function, and used 2x;
#       ### kept like this in case perf matters

#       #say "feature is $feature";
#       #p $href->{feature};
#       p $feature;
#       if(!defined $href->{$feature} ) {
#         push @singleLineOutput, $emptyFieldChar;
#         next PARENT;
#       }

#       if(!ref $href->{$feature} ) {
#         push @singleLineOutput, $href->{$feature};
#         next PARENT;
#       }

#       if(! @{ $href->{$feature} } ) {
#         push @singleLineOutput, $emptyFieldChar;
#         next PARENT;
#       }

#       # if( @{ $href->{$feature} } == 1 && !ref $href->{$feature}[0] ) {
#       #   push @singleLineOutput, defined $href->{$feature}[0] ? $href->{$feature}[0] : 'NA';
#       #   next PARENT;
#       # }

#       #TODO: could break this out into separate function;
#       #need to evaluate performance implications

#       my $accum;
#       ACCUM: foreach ( @{ $href->{$feature} } ) {
#         if(!defined $_) {
#           $accum .= "$emptyFieldChar$primaryDelim";
#           next ACCUM;
#         }

#         # we could have an array of arrays, separate those by commas
#         if(ref $_) {
#           for my $val (@{$_}) {
#             $accum .= defined $val ? "$val$primaryDelim" : "$emptyFieldChar$primaryDelim";
#           }
#           chop $accum;
#           $accum .= $secondDelim;
#           next ACCUM;
#         }

#         $accum .= $_ . $primaryDelim;
#       }

#       chop $accum;
#       push @singleLineOutput, $accum;
#     }

#     $outStr .= join($fieldSeparator, @singleLineOutput) . "\n";
#   }
  
#   return $outStr;
# }

# TODO: In Go, or other strongly typed languages, type should be controlled
# by the tracks. In Perl it carriers no benefit, except here, so keeping here
# Otherwise, the Perl Elasticsearch client seems to treat strings that look like a number
# as a string
# Oh, and the reason we don't store all numbers as numbers in the db is because
# we save space, because Perl's msgpack library doesn't support single-precision
# floats.
# sub indexOutput {
#   my ($self, $outputDataAref) = @_;

#   # my $bulk = $e->bulk_helper(
#   #   index   => 'test_job6', type => 'job',
#   # );

#   my @out;
#   my $count = 1;
#   for my $href (@$outputDataAref) {
#     my %doc;
#     PARENT: for my $feature ( @{$self->outputDataFields} ) {
#       if(ref $feature) {
#           #it's a trackName => {feature1 => value1, ...}
#           my ($parent) = %$feature;

#           CHILD: for my $child (@{ $feature->{$parent} } ) {
#             my $value;
#             if(defined $href->{$parent}{$child} && looks_like_number($href->{$parent}{$child} ) ) {
#               $value = 0 + $href->{$parent}{$child};
#             }

#             if(index($child, ".") > -1) {
#               my @parts = split(/\./, $child);
#               $doc{$parent}{$parts[0]}{$parts[1]} = $value;
#               next CHILD;
#             }

#             $doc{$parent}{$child} = $value;
#           }
#           next PARENT;
#       }
      
#       if(defined $href->{$feature} && looks_like_number($href->{$feature} ) ) {
#         $doc{$feature} = 0 + $href->{$feature};
#         next PARENT;
#       }

#       $doc{$feature} = $href->{$feature};
#       push @out, \%doc;
#     }
#   }
#   # $bulk->index({
#   #     source => \@out,
#   #   });
# }
__PACKAGE__->meta->make_immutable;
1;