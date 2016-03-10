package Seq::Role::Message;

our $VERSION = '0.001';

# ABSTRACT: A class for communicating
# VERSION

# vars that are not initialized at construction

use 5.10.0;
use Moose::Role;
use Redis::hiredis;
use strict;
use warnings;
use namespace::autoclean;
with 'MooX::Role::Logger';
use Carp 'croak';

use Cpanel::JSON::XS;
use DDP;

# my $singleton;

# sub instance {
#   return $singleton //= Seq::Role::Message->new();
# }

# # to protect against people using new() instead of instance()
# around 'new' => sub {
#     my $orig = shift;
#     my $self = shift;
#     return $singleton //= $self->$orig(@_);
# };

# sub initialize {
#     defined $singleton
#       and croak __PACKAGE__ . ' singleton has already been instanciated';
#     shift;
#     return __PACKAGE__->new(@_);
# }

#note: not using native traits because they don't support Maybe attrs
# state @publisherAddress;
# has publisherAddress => (
#   is       => 'ro',
#   isa      => 'Maybe[ArrayRef]',
#   required => 0,
#   lazy     => 1,
#   writer   => '_setPublisherAddress',
#   default  => sub {\@publisherAddress},
# );

# #note: not using native traits because they don't support Maybe attrs
# state %messanger;
# has messanger => (
#   is       => 'rw',
#   isa      => 'Maybe[HashRef]',
#   required => 0,
#   lazy     => 1,
#   writer   => '_setMessanger',
#   default  => sub {\%messanger},
# );

# has _publisher => (
#   is        => 'ro',
#   required  => 0,
#   lazy      => 1,
#   init_arg  => undef,
#   builder   => '_buildMessagePublisher',
#   lazy      => 1,
#   predicate => 'hasPublisher',
#   handles   => { notify => 'command' },
# );

# sub setPublisher {
#   my ($self, $passedMessanger, $passedAddress) = @_;

#   if(!ref $passedMessanger eq 'Hash') {
#     $self->_logger->warn('setPublisher requires hashref messanger, given ' 
#       . ref $passedMessanger);
#     return;
#   }

#   if(%messanger) {
#     $self->_logger->warn('messangerHref exists already in setPublisher');
#   } else {
#     %messanger = %{$passedMessanger};
#     $self->_setMessanger(\%messanger);
#   }

#   if(!ref $passedAddress eq 'ARRAY') {
#     $self->_logger->warn('setPublisher requires ARRAY ref passedAddress, given '
#       . ref $passedAddress);
#     return;
#   }

#   if($passedAddress) {
#     $self->_logger->warn('passedAddress exists already in setPublisher');
#     return;
#   }
#   @publisherAddress = @{$passedAddress};
#   $self->_setPublisherAddress(\@publisherAddress);
# }

# sub _buildMessagePublisher {
#   my $self = shift;
#   return unless $self->publisherAddress;
#   #delegation doesn't work for Maybe attrs
#   return Redis::hiredis->new(
#     host => $self->publisherAddress->[0],
#     port => $self->publisherAddress->[1],
#   );
# }

#note, accessing hash directly because traits don't work with Maybe types
sub publishMessage {
  my ( $self, $msg ) = @_;
  #because predicates don't trigger builders, need to check hasPublisherAddress
  #return unless $self->messanger;
  # $self->messanger->{message}{data} = $msg;
  # $self->notify(
  #   [ 'publish', $self->messanger->{event}, encode_json( $self->messanger ) ] );
}

sub tee_logger {
  my ( $self, $log_method, $msg ) = @_;

  #interestingly some kind of message bufferring occurs, such that
  #this will actually make it through to the rest of the tee_logger function
  if ( $log_method eq 'error' ) {
    return confess "\n$msg\n";
  }

  #$self->publishMessage($msg);
  $self->_logger->$log_method($msg);
}

no Moose::Role;
1;
