#!/usr/bin/perl
# Christian Fenzl, christiantf@gmx.at 2017
# This program provides the following features:
# 1. It can connect to a remote TCP system and mirrors the stream to a UDP guest (TCP -> UDP gateway)
# 2. It can listens to the guest TCP stream, mirrors to a remote TCP stream and mirrors back to the UDP guest (TCP -> TCP -> UDP gateway)
# You can implement an initalization stream and stream processing functions

# Debian Packages required
# - libswitch-perl
# - libio-socket-timeout-perl
# - libfile-pid-perl

use strict;
use warnings;

use Config::Simple;
use Cwd 'abs_path';
# use File::Pid;
use File::HomeDir;
use HTML::Entities;
use IO::Select;
use IO::Socket;
use IO::Socket::Timeout;
use POSIX qw/ strftime /;
use Switch;
use Time::HiRes qw(usleep);
use URI::Escape;

my $home = "/opt/loxberry";
our $tcpin_sock;
our $tcpout_sock;
our $udpout_sock;
our $in_list;
our $out_list;
my $sel;
my $client;

our @rawparts;
our @parts;
our %playerstates;
our $line;


# Creating pid
my $pidfile = "/var/run/lms2udp.$$";
open(my $fh, '>', $pidfile);
print $fh "$$";
close $ph;

# Figure out in which subfolder we are installed
my $part = substr ((abs_path($0)), (length($home)+1));
our ($psubfolder) = (split(/\//, $part))[3];

# Load Configuration from config file
# Read plugin settings
$cfgfilename = "$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg";
# tolog("INFORMATION", "Reading Plugin config $cfgfilename");
if (-e $cfgfilename) {
	print STDERR "Squeezelite Player Plugin LMS2UDP configuration does not exist. Terminating.";
	unlink $pidfile;
	exit(0);
}

my  $syscfg             = new Config::Simple("$home/config/system/general.cfg");

# Read the Plugin config file 
my $cfgversion = trim($cfg->param("Main.ConfigVersion"));
my $squ_server = trim($cfg->param("Main.LMSServer"));
my $squ_lmscliport = trim($cfg->param("Main.LMSCLIPort"));
my $lms2udp_activated = trim($cfg->param("LMS2UDP.activated"));
my $lms2udp_msnr = trim($cfg->param("LMS2UDP.msnr"));
my $lms2udp_udpport = trim($cfg->param("LMS2UDP.udpport"));
my $lms2udp_berrytcpport = trim($cfg->param("LMS2UDP.berrytcpport"));

my $lms2udp_mshost = $syscfg->param("MINISERVER$lms2udp_msnr.IPADDRESS")); 


if ((lc($lms2udp_activated) ne "true") && (lc($lms2udp_activated) ne "yes") && ($lms2udp_activated ne "1")) {
	print STDERR "Squeezelite Player Plugin LMS2UDP is NOT activated in config file. That's ok. Terminating.";
	unlink $pidfile;
	exit(0);
}

if ((! $squ_server) || (! $squ_lmscliport) || (! $lms2udp_mshost) || (! $lms2udp_udpport) || (! $lms2udp_berrytcpport)) {
	print STDERR "Squeezelite Player Plugin LMS2UDP is activated but configuration incomplete. Terminating.";
	unlink $pidfile;
	exit(1);
}

# This is host and port of the remote machine we are communicating with.
my $tcpout_host = $squ_server;
my $tcpout_port = $squ_lmscliport;
# This ist the host we are mirroring commands to the remote machine. Incoming commands from Loxone are mirrored to the remote machine.
my $tcpin_port = $lms2udp_berrytcpport;
# This is the host we mirror the TCP incoming messages to (usually the Miniserver)
my $udpout_host = $lms2udp_mshost;
my $udpout_port = $lms2udp_udpport;

# Create sockets
# Connection to the remote TCP host
$tcpout_sock = create_out_socket($tcpout_sock, $tcpout_port, 'tcp', $tcpout_host);
$tcpout_sock->flush;
## Listen to a guest TCP connection
$tcpin_sock = create_in_socket($tcpin_sock, $tcpin_port, 'tcp');
$in_list = IO::Select->new ($tcpin_sock);

# Create a guest UDP stream
$udpout_sock = create_out_socket($udpout_sock, $udpout_port, 'udp', $udpout_host);
$udpout_sock->flush;

our $answer; 

# When we connect to the remote machine
# In this sub you can send commands to the remote, e.g. query current state or activate a tcp subscription
# Answers are processed later!

tcpout_initialization();

# Now we are ready to listen and process

our $guest;
my $lastpoll = time;
my $pollinterval = 300;


while (1)
{

	# This is the handling of incoming TCP connections (Guests)
	###########################################################
	if (my @in_ready = $in_list->can_read(0.1)) {
		foreach $guest (@in_ready) {
			if($guest == $tcpin_sock) {
				# Create new incoming connection from guest
				my $new = $tcpin_sock->accept;
				$in_list->add($new);
				print "New guest connection accepted\n";
			} else {
				$guest->recv(my $guest_line, 1024);
				# my $guest_line = $guest->getline;
				if ($guest_line) {
					print "Guest: $guest_line\n";
					print $tcpout_sock $guest_line;
					# We close the connection after that
					$in_list->remove($guest);
					$guest->close;
					$guest_line = undef;
				}
			}
		}
	}
	
	# This is the handling of the remote host connection
	###########################################################
	# $tcpout_sock->recv(my $line, 1024);
	my $input = $tcpout_sock->getline;
	if ($input) {
		$input = process_line($input);

		# Debugging with timestamp
		# my ( $sec, $min, $hour) = localtime;
		# my $currtime = strftime("%Y-%m-%dT%H:%M:%S", localtime);
		# print $currtime . " " . uri_unescape($line);
		
		if ($input) {
			print $udpout_sock $input . "\n";
			print $input . "\n";
		}
	}
	
	if ((time%60) == 0) {
		print "DEBUG: Ping-Pong\n";
		print $tcpout_sock "listen 1\n";
		usleep(700000);
	}
	
	if (((time%60) == 0) && (! $tcpout_sock->connected)) {
		
		usleep(700000);
	}
	
	if (! $tcpout_sock->connected)  {
		print "RECONNECT TCP Socket...\n";
			$tcpout_sock = create_out_socket($tcpout_sock, $tcpout_port, 'tcp', $tcpout_host);
			sleep(5);
			if ($tcpout_sock->connected) {
				$udpout_sock->flush;
				sleep (1);
				tcpout_initialization();
			} else { 
				sleep (5);
			}
				
	} 
	if (($lastpoll+$pollinterval) < time)  {
		# Force a periodic poll
		print "FORCING POLL\n";
		print $tcpout_sock "players 0\n";
		$lastpoll = time;
	}
	usleep(200000);
}

# and terminate the connection when we're done

END 
{
	close($tcpout_sock);
	close($udpout_sock);
	close($tcpin_sock);
	
	# Delete pid file
	if (-e "$pidfile") {
		unlink "$pidfile";
	}
}		





#################################################################################
# Initialize remote commection, e.g. query current state
# Params: none
# Returns: none
# Used globals: Sockets $tcpout_sock, $udpout_sock
#################################################################################

sub tcpout_initialization
{
	# For Logitech Media Server: subscribe to get all messages from the server
	#print $tcpout_sock "subscribe playlist,mixer,power,pause\n";
	print $tcpout_sock "listen 1\n";
	# To get everything: "listen 1\n"
	
	# Possibly we also want to welcome Loxone in your nice, little network?
	print $udpout_sock "Hello Loxone, everything perdendicular on your flash drive ? ;-)\n";

	# Get current Players from LMS
	print $tcpout_sock "players 0\n";
}

#################################################################################
# Remote host line processing
# Params: $line
# Returns: Processed $line
# Used globals: Sockets $udpout_sock
#################################################################################

sub process_line 
{
	($line) = @_;
	chomp $line;
	# print "DEBUG Line: $line\n";
	# Prepare two arrays with raw (uri-escaped) and readable (uri-unescaped) parts of the line
	@rawparts = split(/ /, $line);
		
	@parts = split(/ /, $line);
	foreach my $part (@parts) {
		$part = uri_unescape($part);
		# print "PART $part # ";
	}
	
	# 
	# Process the parts through the layers
	#	
	
	switch ($parts[0]) {
		case 'players' 	{ # print "DEBUG: Players\n";
						  return players();
				} # sub for parsing inital player list 
	}
	
	switch ($parts[1]) {
		case 'playlist' { return playlist();}
		case 'mixer' 	{ return mixer();}
		case 'title'	{ $playerstates{$parts[0]}{Songtitle} = $parts[2];
						  print $tcpout_sock "$parts[0] artist ?\n$parts[0] remote ?\n";
						  return undef;}
		case 'artist'	{ 
							if($parts[2]) {
								return "$parts[0] playlist newsong $playerstates{$parts[0]}{Songtitle} - $parts[2]\n";
							} elsif ($playerstates{$parts[0]}{Songtitle}) {
								return "$parts[0] playlist newsong $playerstates{$parts[0]}{Songtitle}\n"; 
							} else { return "$parts[0] playlist newsong Aktuell kein Song\n"; 
							}
					}
		case 'power' 	{ # print "DEBUG: Power\n"; 
						  if ($rawparts[2] == 0) {
							send_state (-2);
							$playerstates{$parts[0]}{Power} = 0;
						} elsif ($rawparts[2] == 1) {
							$playerstates{$parts[0]}{Power} = 1;
							print $tcpout_sock "$rawparts[0] mode ?\n";
						}
						return uri_unescape($line); }
		case 'mode'		{ 
					print "DEBUG: Mode |$rawparts[2]|$parts[2]|\n";
					if ($rawparts[2] eq 'stop') {
						send_state(-1);
					} elsif ($rawparts[2] eq 'play') {
						send_state(1);
					} elsif ($rawparts[2] eq 'pause') {
						send_state(0);
					} else {
						send_state(-2);
					}
				}
		case 'client'	{ return client(); }
		case 'name'		{ return uri_unescape($line); }
		case 'remote'	{ print "$parts[0] DEBUG: remote #$parts[2]#\n";
						  if ($parts[2]) { return "$parts[0] is_stream $parts[2]\n"; } 
						  else { return "$parts[0] is_stream 0\n"; }
				}
	}	
		
	
	return undef;
}

#################################################################################
# Subs for several processing
# Used globals: 
#	- Sockets $tcpout_sock, $udpout_sock
# 	- Part of the line @rawparts and @parts
#	- The full line
# Returns: a full line or undef
#################################################################################

# Remember that the @parts and @rawparts count from 0.
# Therefore, the players MAC usually is [0] and so on.
# Example
# b8:27:eb:6e:2b:f6 playlist newsong Solex 162
# [0]               [1]      [2]     [3]   [4]
sub playlist 
{
	print "DEBUG playlist\n";
	switch ($parts[2]) {
		case 'newsong' {
				if ($rawparts[4]) {
					print $udpout_sock "$parts[0] is_stream 0\n";
					$playerstates{$parts[0]}{Songtitle} = $parts[3];
					print $tcpout_sock "$rawparts[0] artist ?\n";
					send_state(1);
					return undef;
					#return "$parts[0] $parts[1] $parts[2] $parts[3]\n";
				} else { 
					print $udpout_sock "$parts[0] is_stream 1\n";
					print "DEBUG: Playlist thinks $parts[0] is a stream #$rawparts[4]#";
					return uri_unescape($line);}
			}	
		case 'title' {
					$playerstates{$parts[0]}{Songtitle} = $parts[3];
					print $tcpout_sock "$rawparts[0] artist ?\n$rawparts[0] remote ?";
					return undef;
			}
		case 'pause' { 
				if ($playerstates{$parts[0]}{Power} == 0) { return undef; }
				print "DEBUG: Playlist Pause\n";
				if ($rawparts[3] == 1) {
					send_state(0);
				} elsif ($rawparts[3] == 0) {
					send_state(1);
				}
				return uri_unescape ($line);
			}
		case 'stop' { send_state(-1);
					  return undef;
			}
		case 'shuffle' { return uri_unescape ($line); }
		case 'repeat' { return uri_unescape ($line); }
	
	}
		
}

# Everything for 'mixer' control
sub mixer 
{
	if (($parts[3] =~ /^[0-9.]*$/gm)) {
			# The mixer change has an absolute value - we can return the full line
			return(uri_unescape($line));
	} else {
		print $tcpout_sock "$rawparts[0] $rawparts[1] $rawparts[2] ?\n";
		return(undef);
	}
}

sub send_state 
{
	my ($state) = @_;
	switch ($state) {
		case -3		{ print $udpout_sock "$parts[0] mode_text Nicht verbunden\n$parts[0] mode_value -3\n$parts[0] playlist newsong Nicht verbunden\n"; }
		case -2		{ print $udpout_sock "$parts[0] mode_text Aus\n$parts[0] mode_value -2\n$parts[0] playlist newsong Zone ausgeschalten\n"; }
		case -1		{ print $udpout_sock "$parts[0] mode_text Stop\n$parts[0] mode_value -1\n$parts[0] playlist newsong Zone gestoppt\n"; }
		case 0		{ print $udpout_sock "$parts[0] mode_text Pause\n$parts[0] mode_value 0\n"; }
		case 1		{ print $udpout_sock "$parts[0] mode_text Play\n$parts[0] mode_value 1\n"; }
	}
}

sub client
{
	switch ($parts[2]) {
		case 'new'			{ print $tcpout_sock "players 0\n"; }
		case 'reconnect'	{ print $tcpout_sock "players 0\n"; }
		case 'disconnect'	{ print $udpout_sock "$parts[0] connected 0\n"; send_state(-3);}
	
	
	}


}



sub players
{
	my $curr_player;
	my $colon;
	my $tagname;
	my $tagvalue;
	my $out_string = undef;
	
	for my $partnr (0 .. $#parts) {
		# print "DEBUG: #$partnr#$parts[$partnr]#$rawparts[$partnr] #######\n";
		$colon = index ($parts[$partnr], ':');
		if ($colon < 1) { 
			next;
		}
		# print "--$colon--" . substr ($parts[$partnr], 0, $colon) . "----------\n";
		$tagname = substr ($parts[$partnr], 0, $colon);
		$tagvalue = substr($parts[$partnr], $colon+1);
		if ($tagname eq 'playerid') {
			$curr_player = $tagvalue;
			$playerstates{$curr_player}{known} = 1;
			# print "DEBUG: ######### CurPlayer #$curr_player# ############\n";
			print $tcpout_sock "$curr_player power ?\n$curr_player title ?\n$curr_player mixer volume ?\n$curr_player playlist shuffle ?\n$curr_player playlist repeat ?\n$curr_player mixer muting ?\n";
			next;
		} elsif ($curr_player) {
			switch ($tagname) {
				case 'name' 		{ $out_string .= "$curr_player name $tagvalue\n";	}
				case 'connected'	{ $out_string .= "$curr_player connected $tagvalue\n"; }
			}
		}
	}
	return $out_string;
}


#################################################################################
# Create Out Socket
# Params: $socket, $port, $proto (tcp, udp), $remotehost
# Returns: $socket
#################################################################################

sub create_out_socket 
{
	my ($socket, $port, $proto, $remotehost) = @_;
	
	my %params = (
		PeerHost  => $remotehost,
		PeerPort  => $port,
		Proto     => $proto,
		Blocking  => 0
	);
	
	if ($proto eq 'tcp') {
		$params{'Type'} = SOCK_STREAM;
	} elsif ($proto eq 'udp') {
		# $params{'LocalAddr'} = 'localhost';
	}
	if($socket) {
		close($socket);
	}
		
	$socket = IO::Socket::INET->new( %params )
		or die "Couldn't connect to $remotehost:$port : $@\n";
	if ($socket->connected) {
		print "Created $proto out socket to $remotehost on port $port\n";
	} else {
		print "WARNING: Socket to $remotehost on port $port seems to be offline - will retry\n";
	}
	IO::Socket::Timeout->enable_timeouts_on($socket);
	$socket->read_timeout(2);
	$socket->write_timeout(2);
	return $socket;
}

#################################################################################
# Create In Socket
# Params: $socket, $port, $proto (tcp, udp)
# Returns: $socket
#################################################################################

sub create_in_socket 
{

	my ($socket, $port, $proto) = @_;
	
	my %params = (
		LocalHost  => '0.0.0.0',
		LocalPort  => $port,
		Type       => SOCK_STREAM,
		Proto      => $proto,
		Listen     => 5,
		Reuse      => 1,
		Blocking   => 0
	);
	my $socket = new IO::Socket::INET ( %params );
	die "cannot create socket $!\n" unless $socket;
	# In some OS blocking mode must be expricitely disabled
	IO::Handle::blocking($socket, 0);
	print "server waiting for $proto client connection on port $port\n";
	return $socket;
}

#####################################################
# Strings trimmen
#####################################################

sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };
