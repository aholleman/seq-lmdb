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
# state $messanger;
# has messanger => (
#   is       => 'rw',
#   isa      => 'Maybe[HashRef]',
#   required => 0,
#   lazy     => 1,
#   writer   => '_setMessanger',
#   default  => sub { $messanger},
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
# sub publishMessage {
#   #$Seq::Role::Message::pm->start;
#     my ( $self, $event, $msg ) = @_;
#     # to save on perf, $_[0] == $self, $_[1] == $event, $_[2] == $msg;

#     # because predicates don't trigger builders, need to check hasPublisherAddress
#     return unless $_[0]->messanger;
#     $self->messanger->{message}{data} = $msg;
#     $self->notify(
#       [ 'publish', $self->messanger->{event}, encode_json( $self->messanger ) ] );
#   #$Seq::Role::Message::pm->finish;
# }

sub log {
  #return;

  #This gives child process pid $pid disaappeared, A call to `waitpid` outside of Parallel::ForkManager might have reaped it.
  #so don't use parallel $Seq::Role::Message::pm->start and return;
  #and really no performance benefit, since we're already multi-processing our files
  #unless we do a ton of logging

  #my ( $self, $log_method, $msg ) = @_;
  #$_[0] == $self, $_[1] == $log_method, $_[2] == $msg;
  #state $debugLog = AnyEvent::Log::logger("debug");
  #sleep(5);
  #say "in log, looking at $_[1], $_[2]";
  #p $Seq::Role::Message::mapLevels->{$_[1] };
  #log a bunch of messages, helpful on ocassaion
  if(ref $_[2] ) {
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
  #AnyEvent::Log::log $_[1], $_[2];

  if( $_[1] eq 'info' ) {
    $Seq::Role::Message::LOG->INFO( "[INFO] $_[2]" );
  } elsif(  $_[1] eq 'debug' ) {
    $Seq::Role::Message::LOG->DEBUG( "[DEBUG] $_[2]" );
  } elsif( $_[1] eq 'warn' ) {
    $Seq::Role::Message::LOG->WARN( "[WARN] $_[2]" );
  } elsif( $_[1] eq 'fatal' ) {
    $Seq::Role::Message::LOG->ERR( "[ERROR] $_[2]" );
    #$_[0]->publishMessage($_[1], $_[2]);
    die $_[2];
  }

  # if($_[0]->messanger) {
  #   $_[0]->messanger->{message}{data} = $_[1] . $_[2];
  #   $_[0]->notify(
  #     [ 'publish', $_[0]->messanger->{event}, encode_json( $_[0]->messanger ) ] );
  # }
  
  #&{ $Seq::Role::Message::LOG->${ $Seq::Role::mapLevels->{$_[1] } } }( $_[2] );
  #save some performance; could move this to anyevent as well
  #goto &publishMessage; #re-use stack to save performance
  
  #no need for this $Seq::Role::Message::pm->finish;
}

no Moose::Role;
1;
