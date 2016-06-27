package Seq::Role::Message;
use 5.10.0;
use strict;
use warnings;

our $VERSION = '0.001';

# ABSTRACT: A class for communicating to log and to some plugged in messaging service
# VERSION
use Moose::Role 2;

#doesn't work with Parallel::ForkManager;
#for more on AnyEvent::Log
#http://search.cpan.org/~mlehmann/AnyEvent-7.12/lib/AnyEvent/Log.pm
# use AnyEvent;
# use AnyEvent::Log;

use Log::Fast;

$Seq::Role::Message::LOG = Log::Fast->global();
$Seq::Role::Message::LOG = Log::Fast->new({
  level           => 'WARN',
  prefix          =>  '%D %T ',
  type            => 'fh',
  fh              => \*STDOUT,
});

$Seq::Role::Message::mapLevels = {
  info => 'INFO', #\&{$LOG->INFO}
  INFO => 'INFO',
  ERR => 'ERR',
  error => 'ERR',
  fatal => 'ERR',
  warn => 'WARN',
  WARN => 'WARN',
  debug => 'DEBUG',
  DEBUG => 'DEBUG',
  NOTICE => 'NOTICE',
};


use Parallel::ForkManager;
use Redis::hiredis;

use namespace::autoclean;
#with 'MooX::Role::Logger';

use Cpanel::JSON::XS;
use DDP return_value => 'dump';
#TODO: figure out how to not need peopel to do if $self->debug
#instead just use noop

$Seq::Role::Message::pm = Parallel::ForkManager->new(4);

has debug => (
  is => 'ro',
  isa => 'Int',
  lazy => 1,
  default => 0,
);

sub setLogPath {
  my ($self, $path) = @_;
  #open($Seq::Role::Message::Fh, '<', $path);

  #$AnyEvent::Log::LOG->log_to_file ($path);
  $Seq::Role::Message::LOG->config({
    fh => $self->get_write_fh($path),
  });
}

sub setLogLevel {
  my ($self, $level) = @_;
  
  our $mapLevels;

  $Seq::Role::Message::LOG->level( $mapLevels->{$level} );
}

state $messageBase;
state $publisher;
has hasPublisher => (is => 'ro', isa => 'Bool', lazy => 1, default => sub {!!$publisher});

sub setPublisherAndAddress {
  my ($self, $passedMessageBase, $passedAddress) = @_;

  if(!ref $passedMessageBase eq 'Hash') {
    $self->_logger->warn('setPublisherAndAddress requires hashref messanger, given ' 
      . ref $passedMessageBase);
    return;
  }

  $messageBase = $passedMessageBase;

  if(!ref $passedAddress eq 'ARRAY') {
    $self->_logger->warn('setPublisher requires ARRAY ref passedAddress, given '
      . ref $passedAddress);
    return;
  }

  $publisher = Redis::hiredis->new(
    host => $passedAddress->[0],
    port => $passedAddress->[1],
  );
}

# note, accessing hash directly because traits don't work with Maybe types
sub publishMessage {
  # my ( $self, $msg ) = @_;
  # to save on perf, $_[0] == $self, $_[1] == $msg;

  # because predicates don't trigger builders, need to check hasPublisherAddress
  return unless $publisher;
  $messageBase->{message}{data} = $_[1];
  $publisher->command(
    [ 'publish', $messageBase->{event}, encode_json( $messageBase) ] );
}

sub publishProgress {
  # my ( $self, $msg ) = @_;
  # to save on perf, $_[0] == $self, $_[1] == $msg;

  # because predicates don't trigger builders, need to check hasPublisherAddress
  return unless $publisher;
  $messageBase->{message}{data} = { progress => $_[1] };
  $publisher->command(
    [ 'publish', $messageBase->{event}, encode_json( $messageBase ) ] );
}

sub log {
  #my ( $self, $log_method, $msg ) = @_;
  #$_[0] == $self, $_[1] == $log_method, $_[2] == $msg;
 
  if(ref $_[2] ) {
    $_[2] = p $_[2];
  }

  if( $_[1] eq 'info' ) {
    $Seq::Role::Message::LOG->INFO( "[INFO] $_[2]" );

    if($publisher) {
      $_[0]->publishMessage( "[INFO] $_[2]" );
    }

  } elsif(  $_[1] eq 'debug' ) {
    $Seq::Role::Message::LOG->DEBUG( "[DEBUG] $_[2]" );

    if($publisher) {
      $_[0]->publishMessage( "[DEBUG] $_[2]" );
    }

  } elsif( $_[1] eq 'warn' ) {
    $Seq::Role::Message::LOG->WARN( "[WARN] $_[2]" );

    if($publisher) {
      $_[0]->publishMessage( "[WARN] $_[2]" );
    }

  } elsif( $_[1] eq 'fatal' ) {
    $Seq::Role::Message::LOG->ERR( "[FATAL] $_[2]" );
    #$_[0]->publishMessage($_[1], $_[2]);
    
    if($publisher) {
      $_[0]->publishMessage( "[FATAL] $_[2]" );
    }

    die "[FATAL] $_[2]";
  }
}

no Moose::Role;
1;
