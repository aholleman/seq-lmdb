package Seq::Config::Build;

use 5.10.0;
use strict;
use warnings;

use Moose;

=head1 NAME

Seq::Config::Build - The great new Seq::Config::Build!

=head1 VERSION

Version 0.01

=cut

#
# use this to hold an array of SnpTrack & AnnotationTrack
# loop through the array to determine if one of those tracks
# have data a particular point.
#

# attribute / method list
# 1. get abs position from chr / pos
# 2. get chr / pos from abs position
# 3. array of genome-sized tracks
# 4. array of sparse tracks 

my $splice_site_length = 6;

my %idx_codes;
{
  my @bases      = qw(A C G T N);
  my @annotation = qw(0 1);
  my @in_exon    = qw(0 1);
  my @in_gene    = qw(0 1);
  my @is_snp     = qw(0 1);
  my @char       = ( 0 .. 255 );
  my $i          = 0;

  foreach my $base (@bases)
  {
    foreach my $annotation (@annotation)
    {
      foreach my $gene (@in_gene)
      {
        foreach my $exon (@in_exon)
        {
          foreach my $snp (@is_snp)
          {
            $idx_codes{$base}{$annotation}{$gene}{$exon}{$snp} = $char[$i];
            $i++;
          }
        }
      }
    }
  }
}

my %bin_codes;
$bin_codes{typedef}{idx}       = "C C C";
$bin_codes{typedef}{phastCons} = "C";
$bin_codes{typedef}{phyloP}    = "C";

foreach my $kind ( keys %bin_codes )
{
  foreach my $type ( keys %{ $bin_codes{$kind} } )
  {
    $bin_codes{'length'}{$type} = length( pack( $bin_codes{$kind}{$type}, () ) );
  }
}

our $VERSION = '0.01';

has sequence => (
  is => 'rw',
  isa => 'Str',
);

has chr_len => (
  is => 'rw',
  isa => 'HashRef[Str]'
  traits => ['Hash'],
);

has config => (
  is => 'ro',
  isa => 'Seq::Config',
  handles => [ 'chr_names', ],
  required => 1,
);

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Seq::Config::Build;

    my $foo = Seq::Config::Build->new();
    ...

=head1 SUBROUTINES/METHODS

=head2 function1

=cut

sub function1 {
}

=head2 function2

=cut

sub function2 {
}

=head1 AUTHOR

Thomas Wingo, C<< <thomas.wingo at emory.edu> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-seq at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Seq>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Seq::Config::Build


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Seq>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Seq>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Seq>

=item * Search CPAN

L<http://search.cpan.org/dist/Seq/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2015 Thomas Wingo.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see L<http://www.gnu.org/licenses/>.


=cut

__PACKAGE__->meta->make_immutable;

1; # End of Seq::Config::Build
