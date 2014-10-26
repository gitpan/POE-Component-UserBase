#!/usr/bin/perl -w
# $Id: tutorial-chat.perl,v 1.8 2000/12/14 04:08:50 jgoff Exp $

=pod //////////////////////////////////////////////////////////////////////////

Okay... how to write a program using POE.  First we need a program to
write.  How about a simple chat server?  Ok!

First do some preliminary setup things.  Turn on strict, and import
stuff we need.  That will be Socket, for the socket constants and
address manipulation; and some POE classes.  All the POE classes get
POE:: prepended to them when used along with POE.pm itself.  Here are
the ones we need:

POE::Wheel::SocketFactory, to create the sockets.

POE::Wheel::ReadWrite, to send and receive on the client sockets.

POE::Driver::SysRW, to read and write with sysread() and syswrite().

POE::Filter::Line, to process input and output as lines.

POE::Component::UserBase, to allow user authentication.

Here we go:

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

use strict;
use lib '..';
use lib '../blib/lib';
use Socket;
use POE qw( Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Line
	    Component::UserBase );

=pod //////////////////////////////////////////////////////////////////////////

Now we need to create the listening server and wait for connections.
First we define the subroutines that will handle events, and then we
create the POE::Session that maps the event names to the handlers.

But first a quick note about event handler parameters.  Every handler
gets its parameters in some strange order.  Actually, they all get
them in the same order, but the order changes from time to time
(usually between versions).  So Rocco and Artur benchmarked a bunch of
different ways to pass parameters where the order makes no difference.
The least slowest way to do this-- which still is slower than plain
list assignment-- was to use an array slice.

So we came up with some constants for parameter indices into @_, and
exported them from POE::Session (which is automatically included when
you use POE).  Now you can say C<my ($heap, $kernel, $parameter) =
@_[HEAP, KERNEL, ARG0]>, and it will continue to work even if new
parameters are added.  And if parameters are ever removed, well, it
will break at compile time instead of causing sneaky runtime problems.

So anyway, some of the important parameter offsets and what they do:

  KERNEL is a reference to the POE kernel (event loop and services
  object).

  SESSION is a reference to the current POE::Session object.

  HEAP is an anonymous hashref that a session can use to hold its own
  "global" variables.

  FROM is the session that sent the event.

  ARG0..ARG9 are the first ten event parameters.  If you need more
  than that, you can either use ARG9+1..ARG9+$whatever; or you can
  pass parameters as an array reference.  Array references would be
  faster than slinging a bunch of parameters all over the place.

Now about the SocketFactory.  A SocketFactory is a factory that
creates... sockets.  See?  Anyway, the socket factory creates sockets,
but it does not return them right away.  Instead, it waits until the
sockets are ready, and then it sends a "this socket is ready" sort of
success event.  The socket itself is sent as a parameter (ARG0) of the
success event.  And because this is non-blocking (even during
connect), the program can keep working on other things while it waits.

There is more magic.  For listening sockets, it sends the "this socket
is ready" event whenever a connection is successfully accepted.  And
the socket that accompanies the event is the accepted one, not the
listening one.  This makes writing servers real easy, because all the
work between "create this server socket" and "here's your client
connection" is taken care of inside the SocketFactory object.

So here is the server stuff:

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# server_start is the server session's "_start" handler.  It's called
# when POE says the server session is ready to start.  If you're
# familiar with objects, it's sort of like a constructor, only it says
# the object has been constructed already and is ready to be used.  So
# I guess it can be called a "constructed" instead. :)

sub server_start {
  my $heap = $_[HEAP];

  # Create a listening INET/tcp socket.  Store a reference to the
  # SocketFactory wheel in the session's heap.  When the session
  # stops, and the heap is destroyed, the SocketFactory reference
  # count drops to zero, and Perl destroys it for us.  Then it does a
  # little "close the socket" dance inside, and everything is tidy.

  $heap->{listener} = POE::Wheel::SocketFactory->new
    ( BindPort       => 30023,
      Reuse          => 'yes',           # reuse the port right away
      SuccessState   => 'event_success', # event to send on connection
      FailureState   => 'event_failure'  # event to send on error
    );

  print "SERVER: started listening on port 30023\n";
}

# server_stop is the server session's "_stop" handler.  It's called
# when POE says the session is about to die.  Again, OO folks could
# consider it a destructor.  Or and about-to-be-destructed thing.

sub server_stop {

  # Log the server's stopping...

  print "SERVER: stopped.\n";

  # Just make sure the socket factory is destroyed.  This shouldn't
  # really be necessary, but it shows how to use event handler
  # parameters without first using an array slice.

  delete $_[HEAP]->{listener};
}

# server_accept is the server session's "accept" handler.  When a
# session arrives, it's called to do something with the socket that
# was created by accept().

sub server_accept {
  my ($accepted_socket, $peer_address, $peer_port) = @_[ARG0, ARG1, ARG2];

  # The first parameter to SocketFactory's success event is a handle
  # to an established socket (in this case, an accepted one).  For
  # accepted handles, the second and third parameters are the client
  # side's address and port (direct from the accept call's return
  # value).  Oh, but only if it's an AF_INET socket.  They're undef
  # for AF_UNIX sockets, because the PCB says accept's return value is
  # undefined for those.

  # Anyway, translate the peer address to something human-readable,
  # and log the connection.

  $peer_address = inet_ntoa($peer_address);
  print "SERVER: accepted a connection from $peer_address : $peer_port\n";

  # So, we start a new POE::Session to handle the connection.  This is
  # equivalent to forking off a child process to handle a connection,
  # but it stays in the same process.  So it's more like threading, I
  # suppose.

  POE::Session->new
    ( _start      => \&chat_start, # _start event handler
      _stop       => \&chat_stop,  # _stop event handler
      line_input  => \&chat_input, # input event handler
      io_error    => \&chat_error, # error event handler
      out_flushed => \&chat_flush, # flush event handler
      hear        => \&chat_heard, # someone said something

      # A few new states are added to let the application collect
      # the client's username and password, and to validate the
      # clients.

      login             => \&chat_login,             # Request a login name
      password          => \&chat_password,          # Request the password
      authenticate_user => \&chat_authenticate_user, # Ask UserBase to auth
      authenticated     => \&chat_authenticated,     # Is the client valid?

      # To pass arguments to a session's _start handler,
      # include them in an array reference.  For
      # example, the following array reference causes
      # $accepted_handle, $peer_addr and $peer_port to
      # arrive at the chat session's _start event
      # handler as ARG0, ARG1 and ARG2, respectively.

      [ $accepted_socket, $peer_address, $peer_port ]
    );

  # That's all there is to it.  Take the handle, and start a session
  # to cope with it.  Easy stuff.
}

# server_error is the server session's "error" handler.  If something
# goes wrong with creating, reading or writing sockets, this gets
# called to cope with it.

sub server_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];

  # The first three parameters to SocketFactory's error event are the
  # operation that failed, and the numeric and string versions of $!.

  # So log the error already...

  print "SERVER: $operation error $errnum: $errstr\n";

  # And destroy the socket factory.  Destroying it also closes down
  # the listening socket.  After that, this session will run out of
  # things to do and stop.

  delete $heap->{listener};
}

=pod //////////////////////////////////////////////////////////////////////////

This section of the program is the actual chat management.  For the
sake of the tutorial, it is just a hash to keep track of connections
and a subroutine to distribute messages to everyone.

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# This is just a hash of connections, keyed on the connection's
# session reference.  Each element references a record holding the
# un-stringified session reference and maybe some other information
# about the user on the other end of the socket.
#
# Currently, it's [ $session, $user_nickname ].

my %connected_sessions;

# This function takes a kernel reference, the speaker's session, and
# whatever it is that the speaker said.  It formats a message, and
# sends it to everyone listed in %connected_sessions.

sub say {
  my ($kernel, $who) = (shift, shift);
  my $what = join('', @_);

  # Translate the speaker's session to their nickname. Don't say
  # anything if the user doesn't exist

  return unless exists $connected_sessions{$who};
  $who = $connected_sessions{$who}->[1];

  # Send a copy of what they said to everyone.

  foreach my $session (values(%connected_sessions)) {

    # Call the "hear" event handler for each session, with "<$who>
    # $what" in ARG0.  Essentially, this tells them to hear what the
    # user said.

    # It uses call() here instead of post() because of the way
    # departing users are handled.  With post, you get situations
    # where the event is delivered after the user's wheel is gone,
    # leading to runtime errors when the session tries to send the
    # message.  I wimped out and used call() instead of coding the
    # session right; it's okay for just this sample code.

    $kernel->call($session->[0], "hear", "<$who> $what");
  }
}

=pod //////////////////////////////////////////////////////////////////////////

Now we need to handle the accepted client connections.

A quick recap of where the accepted socket currently is.  It was
accepted by the SocketFactory, and passed to &server_accept with the
"we got a connection" event.  Then &server_accept handed it off to a
new POE::Session as a parameter to its _start event.  The _start event
handler (&chat_start) will then get the handle (and the peer address
and port) as ARG0, ARG1 and ARG2.

So anyway, read input from the client connection, process it somehow,
and generate responses.  Here we are at chat_start...

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# Okay... chat_start is the chat session's "_start" handler.  It's
# called after the new POE::Session has been set up within POE.  This
# is POE's way of saying "okay, you're cleared for take off".

sub chat_start {
  my ($heap, $session, $accepted_socket, $peer_addr, $peer_port) =
    @_[HEAP, SESSION, ARG0, ARG1, ARG2];

  # Start reading and writing on the accepted socket handle, parsing
  # I/O as lines, and generating events for input, error, and output
  # flushed conditions.

  $heap->{readwrite} = POE::Wheel::ReadWrite->new
    ( Handle       => $accepted_socket,        # read/write on this handle
      Driver       => POE::Driver::SysRW->new, # using sysread and syswrite
      Filter       => POE::Filter::Line->new,  # filtering I/O as lines
      InputState   => 'line_input',     # generate line_input on input
      ErrorState   => 'io_error',       # generate io_error on error
      FlushedState => 'out_flushed',    # generate out_flushed on flush
    );

  # Initialize the we're-shutting-down flag for graceful quitting.

  $heap->{session_is_shutting_down} = 0;

  # Oh, and log the client session's start.

  print "CLIENT: $peer_addr:$peer_port connected\n";
  $_[KERNEL]->yield('login'); # Present login message to user
}

# And this is the chat session's "destructor", called by POE when the
# session is about to stop.

sub chat_stop {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  $kernel->post
      ( authenticate => log_off => user_name => $heap->{user_name} );

  # If this session still is connected (that is, it wasn't
  # disconnected in an error event handler or something), then tell
  # everyone the person has left.

  if (exists $connected_sessions{$session}) {

    # Log the disconnection.

    print "CLIENT: $connected_sessions{$session}->[1] disconnected.\n";

    # And say goodbye to everyone else (if we haven't already).

    &say($kernel, $session, '[has left chat]')
      unless $heap->{session_is_shutting_down};

    delete $connected_sessions{$session};
  }

  # And, of course, close the socket.  This isn't really necessary
  # here, but it's nice to see.

  delete $heap->{readwrite};
}

# Search for the requested nick, and return whether it was found.
# Jeffrey Goff suggested this function, but I swapped its return
# values.

sub find_nick {
  my $nick_to_find = shift;
  foreach my $session (values(%connected_sessions)) {
    return $session if $session->[1] && $session->[1] eq $nick_to_find;
  }
  return undef;
}

sub is_guest {
  return lc $connected_sessions{shift()}[1] eq 'guest';
}

# This is what the ReadWrite wheel calls when the client end of the
# socket has sent a line of text.  The actual text is in ARG0.

sub chat_input {
  my ($kernel, $heap, $session, $input) = @_[KERNEL, HEAP, SESSION, ARG0];

  # Ignore input if we're shutting down.
  return if $heap->{session_is_shutting_down};

  # Have we gotten an user name from the user yet?

  unless($heap->{user_name}) {
    $heap->{user_name} = $input; # Collect the user name, and
    $kernel->yield('password');  # go to the 'password' state.
    return;
  }

  # Have we gotten a password from the user yet?

  unless($heap->{password}) {
    $heap->{password} = $input;          # Collect the password, and
    $kernel->yield('authenticate_user'); # go atempt to authenticate
    return;                              # the user.
  }

  # Preprocess the input, backspacing over backspaced/deleted
  # characters.  It's just a nice thing to do for people using
  # character-mode telnet.

  1 while ($input =~ s/[^\x08\x7F][\x08\x7F]//g);
  $input =~ tr[\x08\x7F][]d;

  # Parse the client's input for commands, and handle them.  For this
  # little demo/tutorial, we only bother with one or two commands.

  # Just to keep things clean, we'll disable some features for guests.
  # Later on this might be able to be done by UserBase objects by determining
  # a policy of some sort, but for now we'll just base it on the nick.

  # The /nick command.  This changes the user's nickname.  Added nick
  # collision avoidance code by Jeffrey Goff.
  # Guests are not allowed to change nicks, for simplicity's sake.

  if ($input =~ m!^/nick\s+(.*?)\s*$!i && !is_guest($session)) {
    my $nick = $1;
    $nick =~ s/\s+/ /g;

    if (defined &find_nick($nick)) {
      &say($kernel, $session, "[that nickname already is in use, sorry]");
    }
    else {
      &say($kernel, $session, "[is now known as $nick]");
      $connected_sessions{$session} = [ $session, $nick ];

      # Reflect the nick change in persistent storage.
      $heap->{_persistent} = { nick => $nick };
    }
  }

  # The /pass command lets you change passwords for a user name.
  # /pass jgoff cow2dog

  elsif ($input =~ m!^/pass\s+(\w+)\s+(\w+)\s*$!i && !is_guest($session)) {
    if($1 && $2) {
      $kernel->post
	  ( authenticate => update => user_name    => $1,
	                              new_password => $2,
	  );
      &say($kernel, $session, "[Changed user $1 to password $2]");
    }
  }

  # The /create command lets anyone create new users.

  elsif ($input =~ m!^/create\s+(\w+)\s+(\w+)?\s*$!i && !is_guest($session)) {
    my ($user,$pass) = ($1,$2);
    if($pass) {
      $kernel->post
	  ( authenticate => create => user_name => $user,
	                              password  => $pass,
	  );
      &say($kernel, $session, "[Created new user $user, password $pass]");
    } else {
      $kernel->post
	  ( authenticate => create => user_name => $user );
      &say($kernel,$session, "[Created new user $user]");
    }
  }

  # The /delete command lets anyone delete users, with the exception
  # of the guest account

  elsif ($input =~ m!^/delete\s+(\w+)\s*$!i && !is_guest($session)) {
    my $user = $1;
    $kernel->post
	( authenticate => delete => user_name => $user );
    &say($kernel, $session, "[Deleted user $user]");
  }

  # The /quit command works on the principle of least surprise.
  # Everyone expects it, and they want to be polite about
  # disconnecting.

  elsif ($input =~ m!^/quit\s*(.*?)\s*$!i) {
    my $message = $1;
    if (defined $message and length $message) {
      $message =~ s/\s+/ /g;
    }
    else {
      $message = 'no quit message';
    }

    &say($kernel, $session, "[has quit: $message]");

    # Set the we're-shutting-down flag, so we ignore further input
    # *and* disconnect when all output has been flushed to the
    # client's socket.
    $heap->{session_is_shutting_down} = 1;
  }

  # Anything that isn't a recognized command is sent as a spoken
  # message.

  else {
    &say($kernel, $session, $input);
  }
}

# And if there's an I/O error (such as error 0: they disconnected),
# the chat_error handler is called to do something about it.

sub chat_error {
  my ($kernel, $session, $operation, $errnum, $errstr) =
    @_[KERNEL, SESSION, ARG0, ARG1, ARG2];

  # Error 0 is not an error.  It just signals EOF on the socket.  So
  # prettify the error string.

  unless ($errnum) {
    $errstr = 'disconnected';
  }

  # Log the error...

  print( "CLIENT: ", $connected_sessions{$session}->[1],
         " got $operation error $errnum: $errstr\n"
       );

  # Log the user out of the chat server with an error message.

  &say($kernel, $session, "[$operation error $errnum: $errstr]");
  delete $connected_sessions{$session};

  # Delete the ReadWrite wheel.  This closes the handle it's using...
  # unless you have a reference to it somewhere else.  In that case,
  # it just leaks a filehandle 'til you close it yourself.

  delete $_[HEAP]->{readwrite};
}

# This handler is called every time the ReadWrite's output queue
# becomes empty.  It is used to stop the session after a "quit"
# confirmation has been sent to the client.  It is also used to prompt
# the user after all previous output has been sent, but making sure
# you don't go into an infinite loop of prompts (prompting again after
# the prompt has been flushed) is trickier than I want to deal with at
# the moment.

sub chat_flush {
  my $heap = $_[HEAP];

  # If we're shutting down, then delete the I/O wheel.  This will shut
  # down the session.

  if ($heap->{session_is_shutting_down}) {
    delete $heap->{readwrite};
  }
}

# And finally, this is the "hear" event handler.  It's called by the
# &say function whenever someone in the chat server says something.
# ARG0 is a fully-formatted message, suitable for dumping to a socket.

sub chat_heard {
  my ($heap, $what_was_heard) = @_[HEAP, ARG0];

  # This chat session hears nothing if it's shutting down.

  return if $heap->{session_is_shutting_down};

  # Put the message in the ReadWrite wheel's output queue.  All the
  # line-formatting and buffered I/O stuff happens inside the wheel,
  # because its constructor told it to do that (Filter::Line).

  $heap->{readwrite}->put($what_was_heard);

  # And the kernel and the wheel take care of sending it.  Cool, huh?
}

=pod //////////////////////////////////////////////////////////////////////////

Initialize and start the authentication server. The states below are designed
to add authentication to the chat server.

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# Ask the user for a username.

sub chat_login {
  my ($kernel, $heap, $session) =
      @_[KERNEL, HEAP, SESSION];
  $heap->{readwrite}->put('Login:');
  print "CLIENT: $connected_sessions{$session}->[1] collecting user name.\n";
#  print "CLIENT: $connected_sessions{$session}->[0] collecting user name.\n";
}

# Ask the user for a password.

sub chat_password {
  my ($kernel, $heap, $session) =
      @_[KERNEL, HEAP, SESSION];

  $heap->{readwrite}->put('Password:');
  print "CLIENT: $session collecting password.\n";
}

# Now that we've got both a username and password,
# ask the UserBase component if this user/pass is
# valid. It will return to the 'authenticated' state with
# whether it could authenticate the user or not.

sub chat_authenticate_user {
  my ($kernel, $heap, $session) =
      @_[KERNEL, HEAP, SESSION];

  # Post a message to the UserBase component asking to validate
  # the user $heap->{user_name} with the given password. Once the
  # UserBase component figures out whether the user is validated
  # or not, it will return to the state 'authenticated' with whether
  # it was validated or not.

  $kernel->post
      ( authenticate => log_on => user_name  => $heap->{user_name},
	                          password   => $heap->{password},
	                          persistent => $heap,
	                          response   => 'authenticated'
      );
  print "CLIENT: $connected_sessions{$session}->[1] authenticating $heap->{user_name} with $heap->{password}.\n";
}

# Is the user authenticated?
# The results from UserBase come back in an array inside ARG1.
# The first element of the array determines whether the user has
# been authenticated or not. The second element holds the user
# name, the third is the domain, the fourth element is the password,
# and the last is the persistent data that gets returned
# from the database.

sub chat_authenticated {
  my ($kernel, $heap, $session) =
      @_[KERNEL, HEAP, SESSION];
  my $authorized = $_[ARG1][0];
  my $user_name  = $_[ARG1][1];

  if($authorized) {
    print qq(SERVER: Authenticated username $user_name.\n);
    # Find a unique nickname for this user.
    my $nick = $heap->{_persistent}{nick} || $user_name;
    if (defined &find_nick($nick)) {
      my $nick_number = 2;
      $nick_number++ while defined &find_nick($nick . '_' . $nick_number);
      $nick .= '_' . $nick_number;
    }

    # The user's authenticated.  Enter them into the chat hash, and
    # say hello to everyone.
    $connected_sessions{$session} = [ $session, $nick ];
    $heap->{_persistent}{nick} ||= $nick;
    &say($kernel, $session, '[has joined chat]');
  } else {
    # UserBase didn't authenticate the user, so tell the main
    # session to shut down, and give both the client and server
    # reasons as to why it was shut down.

    $heap->{session_is_shutting_down} = 1;
    print qq(SERVER: Could not authenticate username '$user_name'.\n);
    $heap->{readwrite}->put("Could not authenticate you. Good bye.");
  }
}

# Create the UserBase component.
# It'll be known by the alias of 'authenticate', and uses a file
# with the name of './auth.file'. to authenticate from.

POE::Component::UserBase->spawn
  ( Alias    => 'authenticate',
    Protocol => 'file',
    File     => './auth.file',
  );

=pod //////////////////////////////////////////////////////////////////////////

And finally, start the server and run the event queue.

=cut \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# Create a session, mapping event names to the &server_* functions.
# &server_start gets called when the session is ready to go.

new POE::Session( _start        => \&server_start,  # server _start handler
                  _stop         => \&server_stop,   # server _stop handler
                  event_success => \&server_accept, # server connection handler
                  event_failure => \&server_error,  # server error handler
                );

# POE::Kernel, automagically used when POE is used, exports
# $poe_kernel.  It's a reference to the process' global kernel
# instance, which mainly is used to start the kernel.  Like now:

$poe_kernel->run();

# POE::Kernel::run() won't exit until the last session stops.  That
# usually means the program is done with whatever it was doing, and we
# can exit now.

exit;

# Epilogue.  All the custom code in this tutorial is plain Perl
# subroutines.  While POE itself is highly OO, you don't need to know
# much more than four things to use it: How to use a module, how to
# use Perl references, how to create a new object, and how to invoke
# an object method.

# Thanks for reading!
