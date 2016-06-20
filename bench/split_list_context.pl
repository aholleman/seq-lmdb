use Benchmark 'timethese';
use strict;
use warnings;
my $line = "1\tC\t3000\tA\t5\t6";
my $chr = 1;
my $chrLength = length($chr);

sub listContext    { my (undef, undef, $length, undef, undef, $score) = split "\t", $line; }
sub array       { my @out = split "\t", $line;  }
sub justChr       { my $chr = substr($line, 0, index($line, "\t") );  }
sub justChrWithLength       { my $chr = substr($line, 0, $chrLength ? $chrLength : index($line, "\t") );  }

timethese (4_000_000, {
  listContext => \&listContext,
  array => \&array,
  justChr => \&justChr,
  justChrWithLength => \&justChrWithLength,
});

__END__
