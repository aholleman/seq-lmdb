package Seq::Output;
use 5.10.0;
use strict;
use warnings;

use Moose 2;
# use Search::Elastic;

use DDP;

has outputDataFields => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => sub { [] },
  writer => 'setOutputDataFieldsWanted',
);


# ABSTRACT: Knows how to make an output string
# VERSION

#takes an array of <HashRef> data that is what we grabbed from the database
#and whatever else we added to it
#and an array of <ArrayRef> input data, which contains our original input fields
#which we are going to re-use in our output (namely chr, position, type alleles)
sub makeOutputString {
  my ( $self, $outputDataAref) = @_;

  #open(my $fh, '>', $filePath) or $self->log('fatal', "Couldn't open file $filePath for writing");
  # flatten entry hash references and print to file
  my $outStr = '';
  for my $href (@$outputDataAref) {
    
    my @singleLineOutput;

    PARENT: for my $feature ( @{$self->outputDataFields} ) {
      if(ref $feature) {
        #it's a trackName => {feature1 => value1, ...}
        my ($parent) = %$feature;

        if(!defined $href->{$parent} ) {
          #https://ideone.com/v9ffO7
          push @singleLineOutput, map { 'NA' } @{ $feature->{$parent} };
          next PARENT;
        }

        if(!ref $href->{$parent}) {
          push @singleLineOutput, $href->{$parent};
          next PARENT;
        }

        CHILD: for my $child (@{ $feature->{$parent} } ) {
          if(!defined $href->{$parent}{$child} ) {
            push @singleLineOutput, 'NA';
            next CHILD;
          }

          if(!ref $href->{$parent}{$child} ) {
            push @singleLineOutput, $href->{$parent}{$child};
            next CHILD;
          }

          my $accum = '';
          ACCUM: foreach ( @{  $href->{$parent}{$child} } ) {
            if(!defined $_) {
              $accum .= 'NA;';
              next ACCUM;
            }
            # we could have an array of arrays, separate those by commas
            if(ref $_) {
              $accum .= join(";", @$_) . ",";

              next ACCUM;
            }

            $accum .= "$_;";
          }

          chop $accum;
          push @singleLineOutput, $accum;
        }
        next PARENT;
      }

      ### This could be split into separate function, and used 2x;
      ### kept like this in case perf matters

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

      if(! @{ $href->{$feature} } ) {
        push @singleLineOutput, 'NA';
        next PARENT;
      }

      #TODO: could break this out into separate function;
      #need to evaluate performance implications

      my $accum;
      ACCUM: foreach ( @{ $href->{$feature} } ) {
        if(!defined $_) {
          $accum .= 'NA;';
          next ACCUM;
        }

        # we could have an array of arrays, separate those by commas
        if(ref $_) {
          $accum .= ',' . join(";", @$_) . ";";

          next ACCUM;
        }

        $accum .= "$_;";
      }

      chop $accum;
      push @singleLineOutput, $accum;
    }

    $outStr .= join("\t", @singleLineOutput) . "\n";
  }
  
  return $outStr;
}

__PACKAGE__->meta->make_immutable;
1;