package Seq::Output;
use strict;
use warnings;

use Moose 2;

#fields the user wants to
has inputFieldsWantedInOutput => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  default => [],
  writer => 'setInputFieldsWantedInOutput'
);

has outputDataFields => (
  is => 'ro',
  isa => 'ArrayRef',
  lazy => 1,
  writer => 'setOutputDataFieldsWanted',
);

# ABSTRACT: Knows how to make an output string
# VERSION

#takes an array of <HashRef> data that is what we grabbed from the database
#and whatever else we added to it
#and an array of <ArrayRef> input data, which contains our original input fields
#which we are going to re-use in our output (namely chr, position, type alleles)
sub makeOutputString {
  my ( $self, $outputDataAref, $inputDataAref) = @_;

  #open(my $fh, '>', $filePath) or $self->log('fatal', "Couldn't open file $filePath for writing");
  # flatten entry hash references and print to file
  my $totalCount = 0;
  my $outStr;
  for my $href (@$outputDataAref) {
    #first map everything we want from the input file
    my @singleLineOutput = map { $inputDataAref->[$totalCount]->[$_] }
      $self->inputFieldsWantedInOutput;
  
    $totalCount++;

    PARENT: for my $feature ( @{$self->outputDataFields} ) {      
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

__PACKAGE__->meta->make_immutable;
1;