package Seq::Role::Message;
use 5.10.0;
use strict;
use warnings;

our $VERSION = '0.001';

# ABSTRACT: A class for communicating to log and to some plugged in messaging service
# VERSION
use Mouse::Role 2;

#doesn't work with Parallel::ForkManager;
#for more on AnyEvent::Log
#http://search.cpan.org/~mlehmann/AnyEvent-7.12/lib/AnyEvent/Log.pm
# use AnyEvent;
# use AnyEvent::Log;

use Log::Fast;
use namespace::autoclean;
use Beanstalk::Client;
use Cpanel::JSON::XS;
use DDP return_value => 'dump';
use Carp qw/croak/;

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

# Static variables; these need to be cleared by the consuming class
state $debug = 0;
state $verbose = 0;
state $publisher;
state $messageBase;

sub initialize {
  $debug = 0;
  $verbose = 0;
  $publisher = undef;
  $messageBase = undef;
}

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

  if($level =~ /debug/i) {
    $debug = 1;
  }

  $Seq::Role::Message::LOG->level( $mapLevels->{$level} );
}

sub setVerbosity {
  my ($self, $verboseLevel) = @_;
  
  $verbose = !!$verboseLevel;
}

has hasPublisher => (is => 'ro', init_arg => undef, writer => '_setPublisher', isa => 'Bool', lazy => 1, default => sub {!!$publisher});

sub setPublisher {
  my ($self, $publisherConfig) = @_;

  if(!ref $publisherConfig eq 'Hash') {
    return $self->log->('fatal', 'setPublisherAndAddress requires hash');
  }

  if(!( defined $publisherConfig->{server} && defined $publisherConfig->{queue}
  && defined $publisherConfig->{messageBase} ) ) {
    return $self->log('fatal', 'setPublisher server, queue, messageBase properties');
  }

  $publisher = Beanstalk::Client->new({
    server => $publisherConfig->{server},
    default_tube => $publisherConfig->{queue},
    connect_timeout => 1,
  });

  $self->_setPublisher(!!$publisher);

  $messageBase = $publisherConfig->{messageBase};
}

# note, accessing hash directly because traits don't work with Maybe types
sub publishMessage {
  # my ( $self, $msg ) = @_;
  # to save on perf, $_[0] == $self, $_[1] == $msg;

  # because predicates don't trigger builders, need to check hasPublisherAddress
  return unless $publisher;
  
  $messageBase->{data} = $_[1];
  
  $publisher->put({
    priority => 0,
    data => encode_json($messageBase),
  });

  return;
}

sub publishProgress {
  # my ( $self, $annotatedCount, $skippedCount ) = @_;
  #     $_[0],  $_[1],           $_[2]

  # because predicates don't trigger builders, need to check hasPublisherAddress
  return unless $publisher;

  $messageBase->{data} = { progress => $_[1], skipped => $_[2] };

  $publisher->put({
    priority => 0,
    data => encode_json($messageBase),
  });
}

sub log {
  #my ( $self, $log_method, $msg ) = @_;
  #$_[0] == $self, $_[1] == $log_method, $_[2] == $msg;
 
  if(ref $_[2] ) {
    $_[2] = p $_[2];
  }

  if( $_[1] eq 'info' ) {
    $Seq::Role::Message::LOG->INFO( "[INFO] $_[2]" );

    $_[0]->publishMessage( "[INFO] $_[2]" );
  } elsif( $_[1] eq 'debug') {
    $Seq::Role::Message::LOG->DEBUG( "[DEBUG] $_[2]" );

    # do not publish debug messages by default
    if($debug) {
      $_[0]->publishMessage( "[DEBUG] $_[2]" );
    }
  } elsif( $_[1] eq 'warn' ) {
    $Seq::Role::Message::LOG->WARN( "[WARN] $_[2]" );

    $_[0]->publishMessage( "[WARN] $_[2]" );
  } elsif( $_[1] eq 'error' ) {
    $Seq::Role::Message::LOG->ERR( "[ERROR] $_[2]" );
    
    $_[0]->publishMessage( "[ERROR] $_[2]" );

  } elsif( $_[1] eq 'fatal' ) {
    $Seq::Role::Message::LOG->ERR( "[FATAL] $_[2]" );

    $_[0]->publishMessage( "[FATAL] $_[2]" );

    croak("[FATAL] $_[2]");
  }

  if($verbose) {
    say $_[2];
  }

  return;
}

no Mouse::Role;
1;
