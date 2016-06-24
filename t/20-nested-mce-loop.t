use 5.10.0;
use strict;
use warnings;

use Test::More;

plan tests => 5;

use MCE::Loop;

use DDP;

use Parallel::ForkManager;
my $pm = Parallel::ForkManager->new(10);

for my $file (0 .. 9) {
  $pm->start and next;

    my $txNumber;
    my %regionData;
    my %siteData;
    my %positionsCoveredByGenes;
    my %txStartData;

    MCE::Loop->init({
      chunk_size => 1,
      max_workers => 8,
      gather => sub {
        my($chunkID, $dataHref) = @_;

        my ($chr, $data) = %$dataHref;

        say "chr is $chr";
        say "data is";
        p $data;

        for (my $txNumberInChunk = 0; $txNumberInChunk < @$data; $txNumberInChunk++) {
          $txNumber += $txNumberInChunk;

          $regionData{$txNumber} = $data->[$txNumberInChunk]{regionData};

          for my $position ( keys %{ $data->[$txNumberInChunk]{siteData} } ) {
            if( exists $siteData{$position} ) {
              push @{ $siteData{$position} }, [ $txNumber, $data->[$txNumberInChunk]{siteData}{$position} ];
            } else {
              $siteData{$position} = [ [ $txNumber, $data->[$txNumberInChunk]{siteData}{$position} ] ];
            }

            $positionsCoveredByGenes{$position} = 1;
          }

          my ($txStart, $txEnd) = $data->[$txNumberInChunk]{txStartData};

          if( exists $txStartData{$txStart} ) {
            say "txStart exists";
          }

          $txStartData{$txStart} = [$txNumber, $txEnd];
          
        }

        if(exists $perChrData{$chr} ) {
          say "exists";
          push @{ $perChrData{$chr}{regionData} }, @{ $data->{regionData} };
          push @{ $perChrData{$chr}{txStartData} }, @{ $data->{txStartData} };

          for my $pos ( keys %{ $data->{perSiteData} } ) { 
            if (defined )
          }
        }
        $perChrData->{$chr} = $data;
      }
    });

    mce_loop {
      my ($mce, $chunkRef, $chunkID) = @_;

      my $chr = $_;
      my $firstPos = 0;
      my $secondPos = 1;

      MCE->gather($chunkID, {
        #This is one txNumber worth of data, because each key has only one top-level array value
        $chr => { [
          regionData => {
            someKey => "$chr someKey value",
            someKey2 => "$chr someKey value",
          },
          siteData => {
            $firstPos => "pos $firstPos, site Value 1",
            $secondPos => [ "pos $firstPos, site Value 1" ],
          },
          txStartData => {
            "txStart$chunkID" => "txEnd\\$chunkID",
          },
        ] };
      } );
    } (0 .. 9);

    # MCE::Loop::finish;
    
    say "after pushing, perChrData is";
          p $perChrData;

    $pm->finish;
}


 $pm->wait_all_children;