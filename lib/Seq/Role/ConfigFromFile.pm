use 5.10.0;
use strict;
use warnings;

package Seq::Role::ConfigFromFile;

our $VERSION = '0.001';

# ABSTRACT: A moose role for configuring a class from a YAML file
# VERSION

=head1 DESCRIPTION

  @role Seq::Role::ConfigFromFile
  #TODO: Check description

  @example with 'Seq::Role::ConfigFromFile'

Used in:
=for :list
* Seq::Annotate
* Seq::Assembly
* Seq::Fetch

Extended by: None

=cut

use Moose::Role 2;
use MooseX::Types::Path::Tiny qw/ Path /;

use Carp qw/ croak /;
use namespace::autoclean;
use Type::Params qw/ compile /;
use Types::Standard qw/ :types /;
use Scalar::Util qw/ reftype /;
use YAML::XS qw/ Load /;
use DDP;

with 'Seq::Role::IO', 'MooseX::Getopt';

has configfile => (
  is        => 'ro',
  isa       => Path | Undef,
  coerce    => 1,
  predicate => 'has_configfile',
  traits    => ['Getopt'],
);

sub new_with_config {
  state $check = compile( Str, HashRef );
  my ( $class, $opts ) = $check->(@_);
  my %opts;

  my $configfile = $opts->{configfile};

  if ( defined $configfile ) {
    my $hash = $class->get_config_from_file($configfile);
    no warnings 'uninitialized';
    croak "get_config_from_file($configfile) did not return a hash (got $hash)"
      unless reftype $hash eq 'HASH';
    %opts = ( %$hash, %$opts );
  }
  else {
    croak "new_with_config() expects configfile";
  }

  if ( $opts->{debug} ) {
    say "Data for Role::ConfigFromFile::new_with_config()";
    p %opts;
  }

  $class->new( \%opts );
}

sub get_config_from_file {
  #state $check = compile( Str, Object );
  my ( $class, $file ) = @_;

  my $fh = $class->get_read_fh($file);
  my $cleaned_txt;

  while ( my $line = $fh->getline ) {
    chomp $line;
    my $clean_line = $class->clean_line($line);
    $cleaned_txt .= $clean_line . "\n" if ($clean_line);
  }
  return Load($cleaned_txt);
}

no Moose::Role;

1;
