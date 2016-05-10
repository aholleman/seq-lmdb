package Seq::Role::Message;
use 5.10.0;
use strict;
use warnings;

our $VERSION = '0.001';

# ABSTRACT: A class for communicating to log and to some plugged in messaging service
# VERSION
use Moose::Role 2;

#for more on AnyEvent::Log
#http://search.cpan.org/~mlehmann/AnyEvent-7.12/lib/AnyEvent/Log.pm
use AnyEvent;
use AnyEvent::Log;

use Redis::hiredis;

use namespace::autoclean;
#with 'MooX::Role::Logger';

use Cpanel::JSON::XS;
use DDP return_value => 'dump';
#TODO: figure out how to not need peopel to do if $self->debug
#instead just use noop

has debug => (
  is => 'ro',
  isa => 'Int',
  lazy => 1,
  default => 0,
);

sub setLogPath {
  my ($self, $path) = @_;

  $AnyEvent::Log::LOG->log_to_file ($path);
}

sub setLogLevel {
  my ($self, $level) = @_;
  
  $AnyEvent::Log::FILTER->level($level);
}

# $ctx = new AnyEvent::Log::Ctx
#    title   => "dubious messages",
#    level   => "error",
#    log_cb  => sub { print STDOUT shift; 0 },
#    slaves  => [$ctx1, $ctx, $ctx2],
# ;

# sub _buildTeeLogger {
#   my $ctx = new AnyEvent::Log::Ctx
#      title   => "dubious messages",
#      level   => "error",
#      log_cb  => sub { print STDOUT shift; 0 },
#      slaves  => [$ctx1, $ctx, $ctx2],
#   ;
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
  #my ( $self, $event, $msg ) = @_;
  #to save on perf, $_[0] == $self, $_[1] == $event, $_[2] == $msg;

  #because predicates don't trigger builders, need to check hasPublisherAddress
  #return unless $self->messanger;
  # $self->messanger->{message}{data} = $msg;
  # $self->notify(
  #   [ 'publish', $self->messanger->{event}, encode_json( $self->messanger ) ] );
}

sub log {
  #my ( $self, $log_method, $msg ) = @_;
  #$_[0] == $self, $_[1] == $log_method, $_[2] == $msg;
  #state $debugLog = AnyEvent::Log::logger("debug");

  #log a bunch of messages, helpful on ocassaion
  if(ref $_[2] eq 'ARRAY') {
    $_[2] = join('; ', @{$_[2]} );
  }

  if(ref $_[2] eq 'HASH') {
    $_[2] = p $_[2];
  }
  #interestingly some kind of message bufferring occurs, such that
  #this will actually make it through to the rest of the log function
  #synchronous die
  #TODO: Figure out if 'error' level actually quits the program
  #if it does not, then we'll have to override $_[1] to fatal
  # if ( $_[1] eq 'error' ) {
  #   # state $errorLog = AnyEvent::Log::logger("error");
  #   # return $errorLog->($_[2]);

    
  #   #return confess "\n$_[2]\n";
  # }

  #we don't have any complicated logging support, just log if it's not an error
  #$debugLog->("$_[1]: $_[2]");
  # $_[0]->_logger->${ $_[1] }( $_[2] ); # this is very slow, sync to disk
  AnyEvent::Log::log $_[1], $_[2];

  #save some performance; could move this to anyevent as well
  goto &publishMessage; #re-use stack to save performance
}

no Moose::Role;
1;
