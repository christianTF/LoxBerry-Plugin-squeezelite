#!/usr/bin/perl
if (-d "REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/REPLACEFOLDERNAME/lib") {
	use lib 'REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/REPLACEFOLDERNAME/lib';
} else {
	use lib '/opt/loxberry/webfrontend/cgi/plugins/squeezelite/lib';
}
use Basics;

# Christian Fenzl, christiantf@gmx.at 2017
# This script is a gateway from Logitech Media TCP CLI to Loxone Miniserver UDP (for values) and http REST (for text).
# It acts as a proxy with intelligence - LMS-information with missing data is re-collected from LMS first,
# before the full data are sent to the Miniserver.

# Debian Packages required
# - libswitch-perl
# - libio-socket-timeout-perl

# Version of this script
my $version = "0.3.1";


# use strict;
# use warnings;

# Own modules

# Perl modules

use Config::Simple;
use Cwd 'abs_path';
use File::HomeDir;
use HTML::Entities;
use IO::Select;
use IO::Socket;
use IO::Socket::Timeout;
use LWP::UserAgent;
use POSIX qw/ strftime /;
use Switch;
use Time::HiRes qw(usleep);
use URI::Escape;
# use TCPUDP;

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
my $pidfile = "/run/shm/lms2udp.$$";
open(my $fh, '>', $pidfile);
print $fh "$$";
close $fh;

# Read global settings
my  $syscfg             = new Config::Simple("$home/config/system/general.cfg");
our $installfolder   = $syscfg->param("BASE.INSTALLFOLDER");
our $lang            = $syscfg->param("BASE.LANG");
our $miniservercount = $syscfg->param("BASE.MINISERVERS");
our $clouddnsaddress = $syscfg->param("BASE.CLOUDDNS");



# Figure out in which subfolder we are installed
my $part = substr ((abs_path($0)), (length($home)+1));
our ($psubfolder) = (split(/\//, $part))[3];
our $pluginname = $psubfolder;

# Load Configuration from config file
# Read plugin settings
my $cfgfilename = "$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg";
# tolog("INFORMATION", "Reading Plugin config $cfg");
if (! (-e $cfgfilename)) {
	print STDERR "Squeezelite Player Plugin LMS2UDP configuration does not exist. Terminating.\n";
	unlink $pidfile;
	exit(0);
}

# Read the Plugin config file 
our $cfg = new Config::Simple($cfgfilename);

my $lms2udp_activated = $cfg->param("LMS2UDP.activated");
our $cfgversion = $cfg->param("Main.ConfigVersion");
my $squ_server = $cfg->param("Main.LMSServer");
my $squ_lmswebport = $cfg->param("Main.LMSWebPort");
my $squ_lmscliport = $cfg->param("Main.LMSCLIPort");
my $squ_lmsdataport = $cfg->param("Main.LMSDataPort");
my $lms2udp_msnr = $cfg->param("LMS2UDP.msnr");
my $lms2udp_udpport = $cfg->param("LMS2UDP.udpport");
my $lms2udp_berrytcpport = $cfg->param("LMS2UDP.berrytcpport");
our $lms2udp_usehttpfortext = $cfg->param("LMS2UDP.useHTTPfortext");
my $lms2udp_forcepolldelay = $cfg->param("LMS2UDP.forcepolldelay");
my $lms2udp_refreshdelayms = $cfg->param("LMS2UDP.refreshdelayms");

if(! is_true($lms2udp_activated)) {	
	print STDERR "Squeezelite Player Plugin LMS2UDP is NOT activated in config file. That's ok. Terminating.\n";
	unlink $pidfile;
	exit(0);
}

if (is_true($lms2udp_usehttpfortext) || (! $lms2udp_usehttpfortext)) {
	$lms2udp_usehttpfortext = 1; }
else {
	$lms2udp_usehttpfortext = undef;
}



# Init default values if empty
if (! $squ_lmscliport) { $squ_lmscliport = 9090; }
if (! $lms2udp_berrytcpport) { $lms2udp_berrytcpport = 9092; }
if (! $lms2udp_udpport) { $lms2udp_udpport = 9093; }
if (! $lms2udp_forcepolldelay) { $lms2udp_forcepolldelay = 300; }
if (! $lms2udp_refreshdelayms) { $lms2udp_refreshdelayms = 150; }

# Miniserver data
my $miniserver = $lms2udp_msnr;
our $miniserverip        = $syscfg->param("MINISERVER$miniserver.IPADDRESS");
our	$miniserverport      = $syscfg->param("MINISERVER$miniserver.PORT");
our	$miniserveradmin     = $syscfg->param("MINISERVER$miniserver.ADMIN");
our	$miniserverpass      = $syscfg->param("MINISERVER$miniserver.PASS");
my	$miniserverclouddns  = $syscfg->param("MINISERVER$miniserver.USECLOUDDNS");
my	$miniservermac       = $syscfg->param("MINISERVER$miniserver.CLOUDURL");

# Use Cloud DNS?
if ($miniserverclouddns) {
	my $output = qx($home/bin/showclouddns.pl $miniservermac);
	my @fields2 = split(/:/,$output);
	$miniserverip   =  $fields2[0];
	$miniserverport = $fields2[1];
}

print "MSIP $miniserverip MSPORT $miniserverport LMS $squ_server\n";


if ((! $squ_server) || (! $miniserverip) || (! $miniserverport)) {
	print STDERR "Squeezelite Player Plugin LMS2UDP is activated but configuration incomplete. Terminating.\n";
	unlink $pidfile;
	exit(1);
}

# This is host and port of the remote machine we are communicating with.
my $tcpout_host = $squ_server;
my $tcpout_port = $squ_lmscliport;
# This ist the host we are mirroring commands to the remote machine. Incoming commands from Loxone are mirrored to the remote machine.
my $tcpin_port = $lms2udp_berrytcpport;
# This is the host we mirror the TCP incoming messages to (usually the Miniserver)
my $udpout_host = $miniserverip;
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
my $pollinterval = $lms2udp_forcepolldelay;
my $loopdelay = $lms2udp_refreshdelayms*1000;
print "Loop delay: $loopdelay microseconds\n";
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
	usleep($loopdelay);
}

	close $tcpout_sock;
	close $udpout_sock;
	close $tcpin_sock;
# and terminate the connection when we're done

END 
{
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
	print $udpout_sock "Hello Loxone, everything perpendicular on your flash drive ? ;-)\n";

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
							if(defined $parts[2]) {
								to_ms($parts[0], "title", $playerstates{$parts[0]}{Songtitle} . ' - ' .$parts[2]);
								return "$parts[0] playlist newsong $playerstates{$parts[0]}{Songtitle} - $parts[2]\n";
							} elsif (defined $playerstates{$parts[0]}{Songtitle}) {
								to_ms($parts[0], "title", "$playerstates{$parts[0]}{Songtitle}");
								return "$parts[0] playlist newsong $playerstates{$parts[0]}{Songtitle}\n"; 
							} else { 
								to_ms($parts[0], "title", "Aktuell kein Song");
								return "$parts[0] playlist newsong Aktuell kein Song\n"; 
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
		case 'name'		{ to_ms($parts[0], "name", $parts[2]);
						  return uri_unescape($line); }
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
				if (defined $rawparts[4]) {
					print $udpout_sock "$parts[0] is_stream 0\n";
					$playerstates{$parts[0]}{Songtitle} = $parts[3];
					print $tcpout_sock "$rawparts[0] artist ?\n";
					send_state(1);
					return undef;
					#return "$parts[0] $parts[1] $parts[2] $parts[3]\n";
				} else { 
					print $udpout_sock "$parts[0] is_stream 1\n";
					print "DEBUG: Playlist thinks $parts[0] is a stream #$rawparts[4]#\n";
					send_state(1);
					to_ms($parts[0], "title", $parts[3]);
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
		case 'stop' { print $tcpout_sock "$rawparts[0] mode ?\n";
					  #send_state(-1);
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
		case -3		{ 	print $udpout_sock "$parts[0] mode_text Nicht verbunden\n$parts[0] mode_value -3\n$parts[0] playlist newsong Nicht verbunden\n$parts[0] power 0\n"; to_ms($parts[0], "mode", "Nicht verbunden"); to_ms($parts[0], "title", "Nicht verbunden");}
		case -2		{ print $udpout_sock "$parts[0] mode_text Aus\n$parts[0] mode_value -2\n$parts[0] playlist newsong Zone ausgeschalten\n$parts[0] power 0\n"; to_ms($parts[0], "mode", "Zone ausgeschalten"); to_ms($parts[0], "title", "Zone ausgeschalten");}
		case -1		{ print $udpout_sock "$parts[0] mode_text Stop\n$parts[0] mode_value -1\n$parts[0] playlist newsong Zone gestoppt\n$parts[0] power $playerstates{$parts[0]}{Power}\n"; to_ms($parts[0], "mode", "Zone gestoppt"); to_ms($parts[0], "title", "Zone gestoppt");}
		case 0		{ print $udpout_sock "$parts[0] mode_text Pause\n$parts[0] mode_value 0\n$parts[0] power $playerstates{$parts[0]}{Power}\n"; to_ms($parts[0], "mode", "Pause");}
		case 1		{ print $udpout_sock "$parts[0] mode_text Play\n$parts[0] mode_value 1\n$parts[0] power $playerstates{$parts[0]}{Power}\n"; to_ms($parts[0], "mode", "Play");}
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
				case 'name' 		{ $out_string .= "$curr_player name $tagvalue\n"; to_ms($curr_player, "name", $tagvalue);	}
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
	$socket = new IO::Socket::INET ( %params );
	die "cannot create socket $!\n" unless $socket;
	# In some OS blocking mode must be expricitely disabled
	IO::Handle::blocking($socket, 0);
	print "server waiting for $proto client connection on port $port\n";
	return $socket;
}

#####################################################
# Miniserver REST Calls for Strings
# Uses globals
# Used for 
#	- Title
#	- Mode
#	- Player name
#####################################################
sub to_ms 
{
	
	my ($playerid, $label, $text) = @_;
	
	if (! $lms2udp_usehttpfortext) { return; }
	
	#my $playeridenc = uri_escape( $playerid );
	#my $labelenc = uri_escape ( $label );
	my $textenc = uri_escape( $text );
	
	my $player_label = uri_escape( 'LMS ' . $playerid . ' ' . $label);
	
	
	$url = "http://$miniserveradmin:$miniserverpass\@$miniserverip\:$miniserverport/dev/sps/io/$player_label/$textenc";
	$ua = LWP::UserAgent->new;
	$ua->timeout(1);
	# print "DEBUG: #$playerid# #$label# #$text#\n";
	# print "DEBUG: -->URL #$url#\n";
	return $response = $ua->get($url);
}
