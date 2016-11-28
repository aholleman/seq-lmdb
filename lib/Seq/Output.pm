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
  my $delimiters = Seq::Output::Delimiters->new();

  # To try to avoid accessor penalty; 
  # These may be called hundreds of millions of times
  $self->{_primaryDelimiter} = $self->delimiters->primaryDelimiter;
  $self->{_secondaryDelimiter} = $self->delimiters->secondaryDelimiter;
  $self->{_fieldSeparator} = $self->delimiters->fieldSeparator;
  $self->{_emptyFieldChar} = $self->delimiters->emptyFieldChar;
  $self->{_headers} = Seq::Headers->new();
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
  my $emptyFieldChar = $self->{_emptyFieldChar};

  my $trackIdx;

  my $outerDelimiter = $self->{_secondaryDelimiter};
  my $innerDelimiter = $self->{_primaryDelimiter};
  for my $trackData (@$outputDataAref) {
    $trackIdx = 0;

    # p $trackData;
    PARENT: for my $track ( @{ $self->{_headers}->getOrderedHeaderNoMap() } ) {
      #it's a trackName with children: [feature1, feature2, etc]
      if(ref $track) {
        # p $track;
        for my $childIdx (0 .. $#$track) {
          if(!defined $trackData->[$trackIdx][$childIdx]) {
            $trackData->[$trackIdx][$childIdx] = $emptyFieldChar;
          } elsif(ref $trackData->[$trackIdx][$childIdx]) {
            # Debug until the bs with sparse track joining is fixed
            for my $val ( @{$trackData->[$trackIdx][$childIdx]} ) {
              $val //= $emptyFieldChar;

              if(ref $val) {
                $val = join($innerDelimiter, map {
                  # TODO: remove the "," join when the b.s with sparse tracks fixed.
                  $_ ? ( ref $_ ? join(",", map{ $_ || $emptyFieldChar } @$_) : $_ ) : $emptyFieldChar
                } @$val);
              }
              
            }

            $trackData->[$trackIdx][$childIdx] = join($outerDelimiter,
              @{$trackData->[$trackIdx][$childIdx]} ); 

            # TODO: Re-enable
            # $trackData->[$trackIdx][$childIdx] = join("|", map {
            #   $_ ? ( ref $_ ? join(";", map{ $_ || $emptyFieldChar } @{$_}) : $_ ) : $emptyFieldChar
            # } @{$trackData->[$trackIdx][$childIdx]});
      
          }

          
        }


        # p $trackData->[$trackIdx];
        $trackData->[$trackIdx]
        = join("\t", map { $_ || $emptyFieldChar} @{$trackData->[$trackIdx]} );

        # If it has a child, but it is an array, multiallelic or indel
      } elsif(ref $trackData->[$trackIdx]) {
        for my $data ( @{$trackData->[$trackIdx]} ) {
          $data //= $emptyFieldChar;

          if(ref $data) {
            $data = join($innerDelimiter, map { $_ || $emptyFieldChar } @$data);
          }
        }

        $trackData->[$trackIdx] = join($outerDelimiter,
          map { $_ || $emptyFieldChar } @{$trackData->[$trackIdx]}
        );
      }

      if(!defined $trackData->[$trackIdx]) {
        $trackData->[$trackIdx] = $emptyFieldChar;
      }

      # p $trackData->[$trackIdx];

      $trackIdx++;
    }

    $trackData = join("\t", map { $_ || $emptyFieldChar } @$trackData);
  }

  # p @$outputDataAref;

  return join("\n", @$outputDataAref) . "\n";
}
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