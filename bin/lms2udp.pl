#!/usr/bin/perl
use forks qw(stringify);
use forks::shared;
# use threads qw(stringify);
# use threads::shared;

use LoxBerry::IO;
use LoxBerry::Log;
use LoxBerry::JSON;

use warnings;
use strict;

require "$lbphtmlauthdir/lib/LMSTTS.pm";
									
# Christian Fenzl, christiantf@gmx.at 2017-2019
# This script is a gateway from Logitech Media TCP CLI to Loxone Miniserver UDP (for values) and http REST (for text).
# It acts as a proxy with intelligence - LMS-information with missing data is re-collected from LMS first,
# before the full data are sent to the Miniserver.

# Debian Packages required
# - libswitch-perl
# - libio-socket-timeout-perl

# Version of this script
my $version = "1.0.6.3";

print "Startup lms2udp daemon...\n";

# use strict;
# use warnings;

# Own modules

# Perl modules
use Config::Simple;
use Getopt::Long qw(GetOptions);
use HTML::Entities;
use IO::Select;
use IO::Socket;
use IO::Socket::Timeout;
use LWP::UserAgent;
use POSIX qw/ strftime /;
use Switch;
use Time::HiRes qw(usleep);
use URI::Escape;
use Data::Dumper;
# use TCPUDP;

my $home = $lbhomedir;

# Config parameters
my $datafile = "/dev/shm/lms2udp_data.json";
our $cfg;
our $log;
my $cfg_timestamp = 0;
my $lms2udp_activated;
our $cfgversion;
my $squ_server : shared;
my $squ_lmswebport;
my $squ_lmscliport : shared;
my $squ_lmsdataport;
my $lms2udp_msnr : shared;
my $lms2udp_udpport : shared;
my $lms2udp_berrytcpport;
our $lms2udp_usehttpfortext : shared;
my $lms2udp_forcepolldelay;
my $lms2udp_refreshdelayms;

my $miniserverip;
my $miniserverport;
my $miniserveradmin;
my $miniserverpass;

our $sendtoms;
our $tts_lmsvol : shared;
our $tts_minvol : shared = 0;
our $tts_maxvol : shared = 100;
our %mode_string;
my $msi_activated;
our %msi_servers : shared;
#my %msiudpout_sock;
my $msiudpout_sock;
my $msiudpout_sock1;
my $msiudpout_sock2;
my $msiudpout_sock3;
my $msiudpout_sock4;
my $msiudpout_sock5;

our $tcpin_sock;
our $tcpout_sock;
our $udpout_sock;
our $in_list;
our $out_list;
my $sel;

# Variables for player time
my $lms2udp_time_refreshsec=60;  	# Interval: Each x seconds, the player time should be requested from LMS
my $lms2udp_time_nextrefresh=0;		# Stores the actial next time LMS should be queried (epoch)
my $lms2udp_time_sendintervalms=500;# Send the time every x ms to Miniserver / MSG
my $lms2udp_time_nextsend=0;		# Stores the actual time when the next push should happen

our $line;
our $loopdivisor = 3;
our @rawparts;
our @parts;

my %playerstates	: shared;
# The playerstats hash uses the key PLAYERMAC
# It includes the following hash items
	# Known
	# Name
	# Connected
	# Songtitle
	# Artist
	# Cover
	# Album
	# Duration
	# Power
	# Mode
	# Stream
	# Pause
	# Shuffle
	# Repeat
	# volume
	# treble
	# bass
	# time (seconds of the song from the last time query)
	# time_fuzzy (this is the calculated time based on the last time query)
	# time_queried_epoch (epoch time as float of the last 'time' update)
	# sync (comma separated list of playerid's, or undef)
	# State (calculates from Mode and Power to Loxones Mode

our %playerdiffs;
# This hash includes all changes since last UDP-Send

our %threads;

our @tcpout_queue : shared;

print "Plugindir: $lbpplugindir\n";

# Init Logfile
$log = LoxBerry::Log->new (
    name => 'LMS2UDP',
	stderr => 1,
	addtime => 1,
#	nofile => 1,
);
LOGSTART("Daemon LMS2UDP started");

# Creating pid
my $pidfile = "/run/shm/lms2udp.$$";
open(my $fh, '>', $pidfile);
print $fh "$$";
close $fh;


# For debugging purposes, allow option --activate to override disabled setting in the config
my $option_activate;
GetOptions('activate' => \$option_activate) or die "Usage: $0 --activate to override config unactivate\n";

# our $pluginname = $lbpplugindir;

my $cfgfilename = "$lbpconfigdir/plugin_squeezelite.cfg";
read_config();

if ((! $squ_server) || (! $miniserverip) || (! $miniserverport)) {
	LOGCRIT "Squeezelite Player Plugin LMS2UDP is activated but configuration incomplete. Terminating.";
	LOGTITLE "LMS Gateway stopped (no configuration)";
	unlink $pidfile;
	exit(1);
}

# This is host and port of the remote machine we are communicating with.
our $tcpout_host : shared = $squ_server;
our $tcpout_port : shared = $squ_lmscliport;
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

# # Create UDP streams for MSI
# if ( $msi_activated ) {	
	# for my $msino (keys %msi_servers) {
		# my ($host,$port) = split(/:/,$msi_servers{$msino});
		# #
		# # This is really ugly - maybe we find a better solution using a hash with the sub create_out_socket
		# # currently it seems not to work with a hash...
		# #
		# #$msiudpout_sock{$msino} = create_out_socket($msiudpout_sock{$msino}, $port, 'udp', $host);
		# #$msiudpout_sock{$msino}->flush;
		# if ( $msino == 1 ) {
			# $msiudpout_sock1 = create_out_socket($msiudpout_sock1, $port, 'udp', $host);
			# $msiudpout_sock1->flush;
		# }
		# if ( $msino == 2 ) {
			# $msiudpout_sock2 = create_out_socket($msiudpout_sock2, $port, 'udp', $host);
			# $msiudpout_sock2->flush;
		# }
		# if ( $msino == 3 ) {
			# $msiudpout_sock3 = create_out_socket($msiudpout_sock3, $port, 'udp', $host);
			# $msiudpout_sock3->flush;
		# }
		# if ( $msino == 4 ) {
			# $msiudpout_sock4 = create_out_socket($msiudpout_sock4, $port, 'udp', $host);
			# $msiudpout_sock4->flush;
		# }
		# if ( $msino == 5 ) {
			# $msiudpout_sock5 = create_out_socket($msiudpout_sock5, $port, 'udp', $host);
			# $msiudpout_sock5->flush;
		# }
	# }
# }

our $answer; 

LOGOK "Startup ready, sending initial subscriber messages"; 


# When we connect to the remote machine
# In this sub you can send commands to the remote, e.g. query current state or activate a tcp subscription
# Answers are processed later!
tcpout_initialization();

# Now we are ready to listen and process

our $guest;
my $lastpoll = time;
my $last_lms_receive_time;
my $pollinterval = $lms2udp_forcepolldelay;
my $loopdelay = $lms2udp_refreshdelayms*1000;
LOGINF "Loop delay: $loopdelay microseconds";

MSGWEB::start_msgthreads();

start_listening();

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
	
	# if($tl) {
		# $tl->LOGEND("TTS ended");
	# }
}		


#################################################################################
# Listening sub
# Params: none
# Returns: none
#################################################################################

sub start_listening 
{

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
					LOGOK "New guest connection accepted";
					print $new "Welcome - this is Squeezelite Plugin\n";
				} else {
					$guest->recv(my $guest_line, 1024);
					#print $guest "Hallo\n";
					#my @guest_lines = $guest->getlines;
					#foreach my $guest_line (@guest_lines) {
						my $guest_answer;
						chomp $guest_line;
						$guest_line = trim($guest_line);
						LOGINF "GUEST says: $guest_line";
						my @guest_params = split(/ /, $guest_line);
						@guest_params = grep(s/\s*$//g, @guest_params);
						LOGDEB "GUEST_PARAMS[0]: $guest_params[0]";
						if (lc($guest_params[0]) eq 'lmsgtw') {
							LOGINF "GUEST-Param is lmsgtw - entering Plugin commands.";
							switch ($guest_params[1]) {
								case 'currstate' 
									{ $guest_answer = guest_currstate($guest_params[2]); }
								case 'testthread' {
									my $thr = threads->create('testthread', 'b8:27:eb:41:ca:f1');
									$threads{$thr->tid()} = $thr->tid();
									# $thr->join();
								}
								case 'testthread2' {
									my $thr = threads->create('LMSTTS::testthread2', 'b8:27:eb:41:ca:f1');
									$threads{$thr->tid()} = $thr->tid();
									
								}
								
								case 'tts' { 
									# our $thr = threads->create('LMSTTS::tts', ( $tcpout_sock, $guest_line, \%playerstates) );
									
									LMSTTS::tts($tcpout_sock, $guest_line, \%playerstates);
								
									#$thr->join();
									# $guest_answer = LMSTTS::tts($tcpout_sock, \@guest_params, \%playerstates); 
								}
							}
							if ($guest->connected) {
								print $guest $guest_answer;
							}
						} else {
							print $tcpout_sock $guest_line . "\n";
							# We close the connection after that
						}
					#}	
					LOGDEB "GUEST: Closing connection";
					$in_list->remove($guest);
					$guest->close;
					#$guest_lines = undef;
					
				}
			}
		}
		
		# This is the handling of the remote host connection
		###########################################################
		# $tcpout_sock->recv(my $line, 1024);
		my $input;
		my @streamtext;
		@streamtext = $tcpout_sock->getlines;
		foreach $input (@streamtext) {
			LOGDEB "Process LMS incoming: " . trim($input);
			$last_lms_receive_time = time;
			$input = process_line($input);
			# print "Process line finished\n";
			# print $udpout_sock $input . "\n";
			# print $input . "\n";
		}
		# Debugging with timestamp
		# my ( $sec, $min, $hour) = localtime;
		# my $currtime = strftime("%Y-%m-%dT%H:%M:%S", localtime);
		# print $currtime . " " . uri_unescape($line);
		if ((time%60) == 0) {
			LOGDEB "Sending Ping-Pong";
			print $tcpout_sock "listen 1\n";
			usleep(700000);
		}
		
		if (((time%60) == 0) && (! $tcpout_sock->connected)) {
			usleep(700000);
		}
		
		if (! $tcpout_sock->connected || $last_lms_receive_time < (time-65))  {
			if (! $tcpout_sock->connected) { LOGWARN "LMS Socket seems to be down."; }
			if ($last_lms_receive_time < (time-65)) { LOGWARN "LMS2UDP received no data from LMS since 65 seconds (missing Pong to Ping)"; }
			LOGINF "RECONNECT TCP Socket...";
			$tcpout_sock = create_out_socket($tcpout_sock, $tcpout_port, 'tcp', $tcpout_host);
			sleep(5);
			if ($tcpout_sock->connected) {
				$udpout_sock->flush;
				sleep (1);
				LOGOK "Reconnected";
				tcpout_initialization();
			} else { 
				LOGINF "Not reconnected - waiting...";
				sleep (5);
			}
		} 
		if (($lastpoll+$pollinterval) < time)  {
			# Force a periodic poll
			LOGINF "FORCING POLL";
			print $tcpout_sock "players 0\n";
			$lastpoll = time;
		}
		
		# Let's send all the collected data to the Miniserver
		send_to_ms();
		
		# This is the handling of threads
		###########################################################
		foreach(keys %threads) {
			# print "TID-Check: $_\n";
			my $thr = threads->object($_);
			if($thr and $thr->is_joinable()) {
				LOGINF "Thread TID$thr had finished and is joined";
				$thr->join();
				delete $threads{$_};
			}
		}
		
		# # List running threads (for debugging)
		# my @running_t = threads->list(threads::running);
		# # foreach(@running_t) {
			# # print "... TID$_ ";
		# # }
		# # if(@running_t) {
			# # print "\n";
		# # }
		
		# # Close open threads 
		# my @joinable_t = threads->list(threads::joinable);
		# foreach(@joinable_t) {
			# print "Joining TID$_\n";
			# $_->join();
		# }
		
		############################################################
		# Handling of the tcpout_queue
		############################################################
		
		if (@tcpout_queue) {
			threads::shared::lock(@tcpout_queue);
			
			## Schnelles Senden
			while(my $msg = shift(@tcpout_queue)) {
				LOGDEB "Sending TCPOUT queue: $msg";
				print $tcpout_sock $msg . "\n";
				Time::HiRes::sleep(0.003);
			}
			
			## Langsames Senden
			# my $msg = shift(@tcpout_queue);
			# if($msg) {
				# LOGDEB "Sending TCPOUT queue: $msg";
				# print $tcpout_sock $msg . "\n";
			# }
			
		
		}
		
		############################################################
		# Check and re-read config file
		############################################################
		
		if ((time%5) == 0 ) {
			read_config();
		}

		############################################################
		# Time update from LMS
		############################################################
		
		if ($lms2udp_time_nextrefresh < Time::HiRes::time()) {
			foreach my $player (keys %playerstates) {
				if( $playerstates{$player}->{Power} == 1 ) {
					print $tcpout_sock "$player time ?\n";
				}
			}
			$lms2udp_time_nextrefresh = Time::HiRes::time() + $lms2udp_time_refreshsec;
		}
		
		# Here we sleep some time and start over again
		if ($input) {
			LOGINF "Fast response mode";
			usleep($loopdelay/$loopdivisor);
			$input = undef;
		} else {
			usleep($loopdelay);
			$input = undef;
		}
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
	LOGINF "UDP Send: Hello Loxone, here is Squeezelite Player Plugin. Everything perpendicular on your flash drive ? ;-)\n";
	print $udpout_sock "Hello Loxone, here is Squeezelite Player Plugin. Everything perpendicular on your flash drive ? ;-)\n";

	# Get current Players from LMS
	print $tcpout_sock "players 0\nsyncgroups ?\n";
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
			players();
			return undef;
			} # sub for parsing inital player list 
		case 'syncgroups' { syncgroups();
			return undef;
			}
	}
	
	switch ($parts[1]) {
		case 'playlist' { return playlist();}
		case 'mixer' 	{ return mixer();}
		case 'title'	{ 
				pupdate($parts[0], "Songtitle", $parts[2]);
				pupdate($parts[0], "Cover", "http://$squ_server:$squ_lmswebport/music/current/cover.jpg?player=$parts[0]&id=$last_lms_receive_time");
				print $tcpout_sock "$parts[0] artist ?\n$parts[0] album ?\n$parts[0] duration ?\n$parts[0] remote ?\n$parts[0] time ?\n";
				return undef;
			}
		case 'artist'	{   # pupdate($parts[0], "Songtitle", $playerstates{$parts[0]}->{Songtitle});
				if(defined $parts[2]) {
					pupdate($parts[0], "Artist", $parts[2]);
				} else { 
					pupdate($parts[0], "Artist", undef);
				}
				return undef;
			}
		case 'album'	{
				if(defined $parts[2]) {
					pupdate($parts[0], "Album", $parts[2]);
				} else { 
					pupdate($parts[0], "Album", undef);
				}
				return undef;
			}
		case 'power' 	{ # print "DEBUG: $rawparts[0] Power $rawparts[2]\n"; 
				print $tcpout_sock "syncgroups ?\n";
				pupdate($parts[0], "Connected", 1);
				pupdate($parts[0], "Known", 1);
					
				if ($rawparts[2] eq "0") {
					pupdate($parts[0], "Power", 0);
					pupdate($parts[0], "Mode", -1);
					pupdate($parts[0], "Pause", 0);
				} elsif ($rawparts[2] eq "1") {
					pupdate($parts[0], "Power", 1);
					print $tcpout_sock "$rawparts[0] playlist shuffle ?\n";
					print $tcpout_sock "$rawparts[0] playlist repeat ?\n";
					print $tcpout_sock "$rawparts[0] mode ?\n";
					print $tcpout_sock "$rawparts[0] time ?\n";
				}
				return undef;
			}
		case 'mode'		{ 
				LOGDEB "DEBUG: Mode |$rawparts[2]|$parts[2]|\n";
				if (defined $rawparts[2]) {
					if ($rawparts[2] eq 'stop') {
						pupdate($parts[0], "Mode", -1);
						pupdate($parts[0], "Pause", 0);
						pupdate($parts[0], "time", 0);
					} elsif ($rawparts[2] eq 'play') {
						print $tcpout_sock "$rawparts[0] time ?\n";
						pupdate($parts[0], "Mode", 1);
						pupdate($parts[0], "Pause", 0);
					} elsif ($rawparts[2] eq 'pause') {
						pupdate($parts[0], "Mode", 0);
						pupdate($parts[0], "Pause", 1);
					}
				}
				return undef;
			}
		case 'client'	{ return client(); }
		case 'name'	{ pupdate($parts[0], "Name", $parts[2]); 
					return undef;
				}
		case 'remote'	{ # print "$parts[0] DEBUG: remote #$parts[2]#\n";
					if ($parts[2]) { 
						pupdate($parts[0], "Stream", 1);
					} else { 
						pupdate($parts[0], "Stream",  0);
					}
					return undef;
				}
		case 'sync'	{ print $tcpout_sock "syncgroups ?\n$parts[0] title ?\n$parts[0] artist ?\n"; 
					return undef;
				}
		case 'time'	{ pupdate($parts[0], "time", $parts[2]);
					  pupdate($parts[0], "time_fuzzy", $parts[2]);
					  $playerstates{$parts[0]}->{time_queried_epoch} = Time::HiRes::time();
					return undef;
				}
		case 'duration'	{ pupdate($parts[0], "Duration", $parts[2]);
					return undef;
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
	# print "DEBUG playlist #$parts[0]#$parts[1]#$parts[2]#$parts[3]#$parts[4]#\n";
	switch ($parts[2]) {
		case 'newsong' {
				if (defined $rawparts[4]) {
					#$playerstates{$parts[0]}->{Songtitle} = $parts[3];
					#$playerstates{$parts[0]}->{Artist} = undef;
					print $tcpout_sock "$rawparts[0] title ?\n$rawparts[0] artist ?\n$rawparts[0] remote ?\n$rawparts[0] time ?\n";
					#pupdate($parts[0], "Songtitle", $parts[3]);
					#pupdate($parts[0], "Artist", undef);
					return;
					#return "$parts[0] $parts[1] $parts[2] $parts[3]";
				} else { 
					print $tcpout_sock "$rawparts[0] time ?\n";
					pupdate($parts[0], "Stream", 1);
					pupdate($parts[0], "Songtitle", $parts[3]);
					pupdate($parts[0], "Cover", "http://$squ_server:$squ_lmswebport/music/current/cover.jpg?player=$parts[0]&id=$last_lms_receive_time");
					# LOGDEB "DEBUG: Playlist thinks $parts[0] is a stream #$rawparts[4]#";
					return;
				}
			}	
		case 'title' {
					pupdate($parts[0], "Songtitle", $parts[3]);
					pupdate($parts[0], "Cover", "http://$squ_server:$squ_lmswebport/music/current/cover.jpg?player=$parts[0]&id=$last_lms_receive_time");
					print $tcpout_sock "$rawparts[0] artist ?\n$rawparts[0] remote ?\n";
					return undef;
			}
		case 'pause' { 
				if ($playerstates{$parts[0]}->{Power} == 0) { return undef; }
				# LOGDEB "DEBUG: Playlist Pause";
				if ($rawparts[3] == 1) {
					print $tcpout_sock "$rawparts[0] time ?\n";
					pupdate($parts[0], "Pause", 1);
					pupdate($parts[0], "Mode", 0);
				} elsif ($rawparts[3] == 0) {
					print $tcpout_sock "$rawparts[0] time ?\n";
					pupdate($parts[0], "Pause", 0);
					pupdate($parts[0], "Mode", 1);
				}
				return undef;
			}
		case 'stop' { print $tcpout_sock "$rawparts[0] mode ?\n";
					  print $tcpout_sock "$rawparts[0] time ?\n";
					  return undef;
			}
		case 'shuffle' { pupdate($parts[0], "Shuffle", $parts[3]);
						 return undef; }
		case 'repeat'  { pupdate($parts[0], "Repeat", $parts[3]);
						 return undef; }
		case 'cant_open' { print $tcpout_sock "$rawparts[0] mode ?\n"; 
						   return undef; }
	}
}

# Everything for 'mixer' control
sub mixer 
{
	if (! defined($parts[3])) {
		return undef;
	}
	if (($parts[3] =~ /^[0-9.]*$/gm)) {
			# The mixer change has an absolute value - we can return the full line
			pupdate($parts[0], $parts[2], $parts[3]);
			return undef;
	} else {
		print $tcpout_sock "$rawparts[0] $rawparts[1] $rawparts[2] ?\n";
		return(undef);
	}
}

# New Clients connecting, reconnecting or disconnecting
sub client
{
	switch ($parts[2]) {
		case 'new'			{ print $tcpout_sock "$parts[0] name ?\n$parts[0] power ?\n$parts[0] title ?\n$parts[0] artist ?\n$parts[0] mixer volume ?\n$parts[0] playlist shuffle ?\n$parts[0] playlist repeat ?\n$parts[0] mixer muting ?\n$parts[0] time ?\n";
							  pupdate($parts[0], "Connected", 1);
							  pupdate($parts[0], "Known", 1);
							}
		case 'reconnect'	{ print $tcpout_sock "$parts[0] name ?\n$parts[0] power ?\n$parts[0] title ?\n$parts[0] artist ?\n$parts[0] mixer volume ?\n$parts[0] playlist shuffle ?\n$parts[0] playlist repeat ?\n$parts[0] mixer muting ?\n$parts[0] time ?\n"; 
							  pupdate($parts[0], "Connected", 1);
							  pupdate($parts[0], "Known", 1);
							}
							  
		case 'disconnect'	{ 
							  pupdate($parts[0], "Power", 0);
							  pupdate($parts[0], "Mode", -1);
							  pupdate($parts[0], "Pause", 0);
							  pupdate($parts[0], "Connected", 0);
							  pupdate($parts[0], "Known", 1);
							  pupdate($parts[0], "time", 0);
							}
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
			pupdate($curr_player, "Known" , 1);
			# print "DEBUG: ######### CurPlayer #$curr_player# ############\n";
			print $tcpout_sock "$curr_player power ?\n";
			print $tcpout_sock "$curr_player title ?\n";
			print $tcpout_sock "$curr_player artist ?\n";
			print $tcpout_sock "$curr_player mixer volume ?\n";
			print $tcpout_sock "$curr_player playlist shuffle ?\n";
			print $tcpout_sock "$curr_player playlist repeat ?\n";
			print $tcpout_sock "$curr_player mixer muting ?\n";
			print $tcpout_sock "$curr_player time ?\n";
			next;
		} elsif ($curr_player) {
			switch ($tagname) {
				case 'name' { 
						pupdate($curr_player, "Name", $tagvalue);
					}
				case 'connected' { 
						pupdate($curr_player, "Connected", $tagvalue);
						}
			}
		}
	}
	return undef;
}

sub syncgroups 
{
	# print "DEBUG: SYNCGROUPS entering\n";
	# First we set all syncs to undef 
	foreach my $player (keys %playerstates) {
		if ($playerstates{$player}->{sync}) {  
			pupdate($player, "sync", undef);
		}
	}
	
	# Nothing synced here
	if (! $rawparts[1]) {
		# print "DEBUG: Currently no syncgroups\n";
		return undef;
	}
	
	# Split the members
	for my $groups (1 .. $#rawparts) {
		# print "Group $groups is $rawparts[$groups]\n";
		my ($key, $group) = split(/:/, uri_unescape($rawparts[$groups]), 2);
		if ($key eq "sync_members") {
			my @members = split(/,/, $group);
			#print $tcpout_sock "$members[0] title ?\n";
			pupdate($members[0], "sync", join(',', @members));
		} 
	}
}

##################################################################
# pupdate
# Used to save current LMS state and create a diff hash
##################################################################
sub pupdate 
{
	my ($player, $key, $value) = @_;
	my $newkey_flag = 0;
	LOGDEB "pupdate: $player | $key | $value";
	return if (!$player or !defined $key);
		
	if (! defined $playerstates{$player}) {
		LOGDEB "Playerstates: Create new player $player";
		$newkey_flag = 1;
		my %player_href : shared;
		$player_href{$key} = $value;
		$playerstates{$player} = \%player_href;
		$playerdiffs{$player}{$key} = $value;
	} else {
		LOGDEB "pupdate: Value updated.";
		$playerdiffs{$player}{$key} = $value;# if ( $value ne $playerstates{$player}->{$key} );
		my $currplayer = $playerstates{$player};
		$$currplayer{$key} = $value;
	}
	
	# Sync setting to sync members
	return if( $key eq "Power" and $value eq "0" );
	return if( !$playerstates{$player}->{sync} );
	return if( $playerstates{$player}->{Power} == 0 and $key eq "Pause" );
	return if( $playerstates{$player}->{Power} == 0 and $key eq "Mode" );
	
	###############################################
	#
	# HINT SCHLENN: Add Album and Cover here, too?
	#
	###############################################
	my @syncKeys = qw ( Songtitle Artist Album Cover Stream Pause Shuffle Repeat sync Mode time time_queried_epoch );
	if( grep { $key eq $_ } @syncKeys ) {
		foreach my $member ( get_members($playerstates{$player}->{sync}) ) {
			next if (!defined $playerstates{$member});
			next if ($member eq $player); # Don't sync itself
			next if ($playerstates{$member}->{Power} == 0 and $key eq "Pause"); # Don't sync pause state on powered off players
			next if ($playerstates{$member}->{Power} == 0 and $key eq "Mode"); # Don't sync pause state on powered off players

			LOGDEB "pupdate: Replicating $key=$value from $player to $member";
			$playerdiffs{$member}{$key} = $value if ( $playerstates{$member}->{$key} ne $value ); 
			$playerstates{$member}->{$key} = $value;
			
		}
	}
	
}

##
## Return members array from sync string
##
sub get_members
{
	my ($membersStr) = @_;
	my @members = split(/,/, $membersStr);
	return @members;
}


#####################################################################################
## Here are routines for guest requests
#####################################################################################

#####################################################################################
# lmsgtw currstate [playerid] -> sends all known info about all or specified player

sub guest_currstate
{
	my ($player) = @_;
	my $answer; 
	LOGDEB "GUEST: Requesting current state";
	$answer .= "-------------------------------------------------------\n";
	# If one player was requested
	if ($player) {
			$player = uri_unescape($player);
			$answer .= " Guest requested player state for $player $playerstates{$player}->{Name}\n";
			if (! $playerstates{$player}) {
				$answer .= "  --> This player does not exist.";
			} else {
				foreach my $setting (sort keys %{$playerstates{$player} }) {
					$answer .= "$setting: $playerstates{$player}->{$setting}\n";
				}
			}
		} else {
			# No player specified - list all
			foreach $player (sort keys %playerstates) {
				$answer .= "-------------------------------------------------------\n";
				$answer .= "Player $player $playerstates{$player}->{Name}\n";
				foreach my $setting (sort keys %{$playerstates{$player} }) {
					$answer .= "$setting: $playerstates{$player}->{$setting}\n";
				}
			}
		$answer .= "-------------------------------------------------------\n";
	}
	LOGDEB "GUEST: Current state sent";
	return $answer;
}

#####################################################
# Send the collected data to the Loxone Miniserver
# but incremental updates only :-)
#####################################################
sub send_to_ms()
{
	# Check sync states on players with status change
	# and populate mode texts to titles
	foreach my $player (keys %playerdiffs) {
		
		if($player eq "") {
			delete $playerdiffs{$player};
			next;
		}
		if (!defined $playerstates{$player}) 
			{ next; }
	
		# Calculate the internal state = Loxone Mode 
		if (defined $playerdiffs{$player}{Mode} or defined $playerdiffs{$player}{Power} or defined $playerdiffs{$player}{Connected}) {
			if($playerstates{$player}->{Connected} == 0) {
				pupdate($player, "State", -3);
				next;
			}
			if(!defined $playerstates{$player}->{Power} or $playerstates{$player}->{Power} == 0) {
				pupdate($player, "State", -2);
				#$playerdiffs{$player}{State} = -2;
				next;
			} else {
				if($playerstates{$player}->{Mode} == -1) {
					pupdate($player, "State", -1);
					#$playerdiffs{$player}{State} = -1;
					next;
				} elsif ($playerstates{$player}->{Mode} == 0) {
					pupdate($player, "State", 0);
					#$playerdiffs{$player}{State} = 0;
				} elsif ($playerstates{$player}->{Mode} == 1) {
					#$playerdiffs{$player}{State} = 1;
					pupdate($player, "State", 1);
				}
			}
		}
	}


	# Now we send the changes to MS and MSI
	my $udpout_string;
	my %msiudpout_string;
	my $msiserver;
	my $msizone;
	my $msisend = 1;
	my $data_changed;
	
	
	# Time update for MS/MSG
		
	if ($lms2udp_time_nextsend < Time::HiRes::time()) {
		# LOGDEB "Time update";
		foreach my $player (keys %playerstates) {
			if( $playerstates{$player}->{Mode} == 1 ) {
				# Calculate the current time
				$playerdiffs{$player}{time} = $playerstates{$player}{time} + Time::HiRes::time() - $playerstates{$player}{time_queried_epoch};
				pupdate($player, 'time_fuzzy', $playerdiffs{$player}{time});
			}
		}
		$lms2udp_time_nextsend = Time::HiRes::time() + $lms2udp_time_sendintervalms/1000;
		$data_changed = 1;
	}
		
	
	
	
	foreach my $player (keys %playerdiffs) {
		
		# Mode and title changes for each player
		my $title_artist;
		my $songtitle;
		my $artist;

		# Which Zone and MusicServer
		# if ( $msi_activated ) {
			# $msiserver = $msi_players{$player};
			# $msizone = $msi_zones{$player};
		# }
		# if ( !$msiserver || !$msizone || !$msi_activated ) {
			# $msisend = 0;
		# }

		if ( 
			defined $playerdiffs{$player}{Songtitle} or 
			defined $playerdiffs{$player}{Artist} or 
			defined $playerdiffs{$player}{Album} or 
			defined $playerdiffs{$player}{State} ) {
			
				# Wenn eine Änderung gekommen ist, passiert das, wenn er nicht läuft
				if ( $playerstates{$player}->{State} == -3 ) {
					$title_artist = $mode_string{-3};
				} elsif ( $playerstates{$player}->{State} == -2 ) {
					$title_artist = $mode_string{-2};
				} elsif ( $playerstates{$player}->{State} == -1 ) {
					$title_artist = $mode_string{-1};
				} elsif ( $playerstates{$player}->{State} == 0 ) {
					$title_artist = $mode_string{0};
				} elsif ( $playerstates{$player}->{State} == 1 ) {
					if( ( $playerdiffs{$player}{Songtitle} and $playerstates{$player}->{Artist} ) or $playerstates{$player}->{Artist} ) {
						# Jede Änderung von Titel+Artist oder nur Artist
						$title_artist = "$playerstates{$player}->{Songtitle} - $playerstates{$player}->{Artist}";
						$songtitle = "$playerstates{$player}->{Songtitle}";
						$artist = "$playerstates{$player}->{Artist}";
					} elsif ($playerstates{$player}->{State} == 1 and defined $playerdiffs{$player}{Songtitle}) {
						# Jede Änderung des Titels
						$title_artist = "$playerstates{$player}->{Songtitle}";
						$songtitle = "$playerstates{$player}->{Songtitle}";
						$artist = "";
					} else {
						#$title_artist = "UNKNOWN";
						#$songtitle = "UNKNOWN";
					}
				} else {
					$title_artist = "UNDEFINED STATE";
					$songtitle = "UNDEFINED STATE";
				}
			}
		# LOGDEB "SONGTITLE calculated: $title_artist";
		
		if ($title_artist) {
			$playerstates{$player}->{SentSongtitle} = $title_artist;
			to_ms($player, "title", $playerstates{$player}->{SentSongtitle});
			to_ms($player, "songtitle", $songtitle);
			to_ms($player, "artist", $artist);
			to_ms($player, "cover", "$playerstates{$player}->{Cover}");
			to_ms($player, "album", "$playerstates{$player}->{Album}");
			$udpout_string .= "$player playlist newsong $title_artist\n";
			$msiudpout_string{$msiserver} .= "$msizone\::setCover::$playerstates{$player}->{Cover}\n";
			$msiudpout_string{$msiserver} .= "$msizone\::setArtist::$artist\n";
			$msiudpout_string{$msiserver} .= "$msizone\::setAlbum::$playerstates{$player}->{Album}\n";
			$msiudpout_string{$msiserver} .= "$msizone\::setTitle::$songtitle\n";
			$data_changed = 1;
		}
			
		foreach my $setting (keys %{$playerdiffs{$player} }) {
		# Limit sending lenght to ~200
			if (length($udpout_string) > 200) {
				if ($sendtoms) {
					print $udpout_sock $udpout_string;
					LOGINF ">>>>>  START SEND TO MS (UDP) >>>>>\n" .
						trim($udpout_string);
					LOGINF "<<<<< FINISHED SEND TO MS (UDP) <<<<< (" . length($udpout_string) . " Bytes)";
				}
				LOGDEB "Fast response mode";
				usleep($loopdelay/$loopdivisor);
				$data_changed = 1;
				$udpout_string = undef;
			}

			switch ($setting) {
				case 'Name'		{ to_ms($player, "name", $playerdiffs{$player}{$setting});
							  $udpout_string .= "$player name $playerdiffs{$player}{$setting}\n";
							  next;
							}
				case 'State'		{ to_ms($player, "mode", $mode_string{$playerdiffs{$player}{$setting}});
							  $udpout_string .= "$player mode_value $playerdiffs{$player}{$setting}\n";
							  $udpout_string .= "$player mode_text $mode_string{$playerdiffs{$player}{$setting}}\n";
							  next;
							} 
				case 'Power'		{ $udpout_string .= "$player power $playerdiffs{$player}{$setting}\n"; next;}
				case 'Shuffle' 		{ $udpout_string .= "$player playlist shuffle $playerdiffs{$player}{$setting}\n"; next;}
				case 'Repeat' 		{ $udpout_string .= "$player playlist repeat $playerdiffs{$player}{$setting}\n"; next;}
				case 'Stream' 		{ $udpout_string .= "$player is_stream $playerdiffs{$player}{$setting}\n"; next;}
				case 'volume' 		{ $udpout_string .= "$player mixer volume $playerdiffs{$player}{$setting}\n"; next;}
				case 'bass' 		{ $udpout_string .= "$player mixer bass $playerdiffs{$player}{$setting}\n"; next;}
				case 'treble' 		{ $udpout_string .= "$player mixer treble $playerdiffs{$player}{$setting}\n"; next;}
				case 'muting' 		{ $udpout_string .= "$player mixer muting $playerdiffs{$player}{$setting}\n"; next;}
				case 'Connected'	{ $udpout_string .= "$player connected $playerdiffs{$player}{$setting}\n"; next;}
				case 'Duration'		{ $udpout_string .= "$player duration $playerdiffs{$player}{$setting}\n";
							  $msiudpout_string{$msiserver} .= "$msizone\::setDuration::$playerdiffs{$player}{$setting}\n";
				       			  next;
						  	}
				case 'time'		{ $udpout_string .= "$player time $playerdiffs{$player}{$setting}\n";
							  $msiudpout_string{$msiserver} .= "$msizone\::setTime::$playerdiffs{$player}{$setting}\n";
				       			  next;
						  	}
				case 'sync'		{ my $is_synced;
							  if ($playerdiffs{$player}{$setting}) {
								$is_synced = 1;
							  } else {
								$is_synced = 0;
							  }
							  $udpout_string .= "$player is_synced $is_synced\n";
							  next;
							}
			}
		}
	}	
	if ($udpout_string) {
		if($sendtoms) {
			print $udpout_sock $udpout_string;
			LOGINF ">>>>> START SEND TO MS (UDP) >>>>>\n" .
				trim($udpout_string);
			LOGINF "<<<<< FINISHED SEND TO MS (UDP) <<<<< (" . length($udpout_string) . " Bytes)";
		}
		$data_changed = 1;
	}

	# MSI
	if ( $msi_activated && $msisend ) {
		for (my $i=1;$i <= 5; $i++) { # 5 Musicserver max
			if ($msiudpout_string{$i}) {
				#
				# This is really ugly - maybe we find a better solution using a hash with the sub create_out_socket
				# currently it seems not to work with a hash...
				#
				if ( $i == 1 ) { $msiudpout_sock = $msiudpout_sock1; }
				if ( $i == 2 ) { $msiudpout_sock = $msiudpout_sock2; }
				if ( $i == 3 ) { $msiudpout_sock = $msiudpout_sock3; }
				if ( $i == 4 ) { $msiudpout_sock = $msiudpout_sock4; }
				if ( $i == 5 ) { $msiudpout_sock = $msiudpout_sock5; }
				#print $msiudpout_sock{$i} $msiudpout_string{$i};
				# Sending a string splitted by linefeeds \n seems not to work with MSI Plugin.
				# So loop through the msiudpout_string...
				my @lines = split(/\n/,$msiudpout_string{$i});
				foreach (@lines) {
					print $msiudpout_sock "$_";
				}
				LOGINF ">>>>> START SEND TO MSI No. $i (UDP) >>>>>\n" .
					trim($msiudpout_string{$i});
				LOGINF "<<<<< FINISHED SEND TO MSI No. $i (UDP) <<<<< (" . length($msiudpout_string{$i}) . " Bytes)";
			}
		}
	}

	if ($data_changed) {
		# Generate JSON file for UI
		LOGINF "Writing current LMS data to $datafile";
		# unlink $datafile;
		my $lmsjsonobj = LoxBerry::JSON->new();
		my $lmsjson = $lmsjsonobj->open(filename => $datafile);
		$lmsjson->{States} = \%playerstates;
		$lmsjsonobj->write();
		undef $lmsjsonobj;
	}
	
	undef %playerdiffs;


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
	sleep (0.02);
	if ($socket->connected) {
		LOGOK "Created $proto out socket to $remotehost on port $port";
	} else {
		LOGWARN "Socket to $remotehost on port $port seems to be offline - will retry";
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
	LOGOK "server waiting for $proto client connection on port $port";
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
	
	if (! $lms2udp_usehttpfortext || !$sendtoms) { return; }
	
	my $player_label = 'LMS ' . $playerid . ' ' . $label;
		
	## Direct method - replaced by LoxBerry::IO::mshttp_send
	# my $textenc = uri_escape( $text );
	# my $player_label = uri_escape( 'LMS ' . $playerid . ' ' . $label);
	
	# $url = "http://$miniserveradmin:$miniserverpass\@$miniserverip\:$miniserverport/dev/sps/io/$player_label/$textenc";
	# $url_nopass = "http://$miniserveradmin:*****\@$miniserverip\:$miniserverport/dev/sps/io/$player_label/$textenc";
	# $ua = LWP::UserAgent->new;
	# $ua->timeout(1);
	# LOGDEB "to_ms (http): #$playerid# #$label# #$text#";
	# LOGDEB "to_ms (http): URL $url_nopass";
	# $response = $ua->get($url);
	# return $response;
	
	## New: With mshttp_send_mem
	
	LOGDEB "to_ms (http): #$playerid# #$label# #$text#";
	my $http_response;
	eval {
	$http_response = LoxBerry::IO::mshttp_send( $lms2udp_msnr, $player_label, $text);
	};
	if ($@) {
		LOGERR "to_ms (http): FAILED #$playerid# #$label# #$text# Exception catched: $@";
		return;
	}
	if (! $http_response) {
		LOGDEB "to_ms (http): WARNING: Could not set '$player_label' (VI/VTI not available?)";
	}
}

#####################################
# search_in_playerstate
# Search for the existance of $needle (param 2) in player $subkey (param 1)
# and return the hashkey (player mac) on existance
# Example: Search "Büro" in {Player}{Name} -> $mac = search_in_playerstate("Name", "Büro");
sub search_in_playerstate
{
	my ($subkey, $needle) = @_;
	
	foreach my $mac (keys %playerstates) {
		if($playerstates{$mac}->{$subkey} eq $needle) {
			return $mac;
		}
	}
	
	return undef;
}


#####################################
# read_config
# Reads and re-reads the config
sub read_config
{

	# Check existance of config file
	if (! (-e $cfgfilename)) {
		LOGCRIT "Squeezelite Player Plugin LMS2UDP configuration does not exist. Terminating.\n";
		LOGTITLE "LMS Gateway stopped (no configuration)";
		unlink $pidfile;
		exit(0);
	}
	
	# Check if config has changed
	my $mtime = (stat($cfgfilename))[9];
	if($cfg_timestamp == $mtime and $cfg) {
		return;
	}
	
	LOGINF "Reading Plugin config $cfgfilename";
	$cfg_timestamp = $mtime;
		
	# Read the Plugin config file 
	$cfg = new Config::Simple($cfgfilename);

	$lms2udp_activated = $cfg->param("LMS2UDP.activated");
	$cfgversion = $cfg->param("Main.ConfigVersion");
	$squ_server = $cfg->param("Main.LMSServer");
	$squ_lmswebport = $cfg->param("Main.LMSWebPort");
	$squ_lmscliport = $cfg->param("Main.LMSCLIPort");
	$squ_lmsdataport = $cfg->param("Main.LMSDataPort");
	$lms2udp_msnr = $cfg->param("LMS2UDP.msnr");
	$lms2udp_udpport = $cfg->param("LMS2UDP.udpport");
	$lms2udp_berrytcpport = $cfg->param("LMS2UDP.berrytcpport");
	$lms2udp_usehttpfortext = $cfg->param("LMS2UDP.useHTTPfortext");
	$lms2udp_forcepolldelay = $cfg->param("LMS2UDP.forcepolldelay");
	$lms2udp_refreshdelayms = $cfg->param("LMS2UDP.refreshdelayms");
	$sendtoms = $cfg->param("LMS2UDP.sendToMS");

	# Read MSI config from config
	$msi_activated = $cfg->param("MSI.Activated");
	if ( $msi_activated ) {	
		LOGINF "MSI is ENABLED";
		require "$lbphtmlauthdir/lib/msgwebserver.pm";
		for ( my $i=1; $i<=5; $i++ ) { # 5 MusicServer max
			my $LocalWebPort;
			if ( $cfg->param("MSI.Musicserver$i\_Ip") ) {
				if (! $cfg->param("MSI.Musicserver$i\_Port") ) {
					$cfg->param("MSI.Musicserver$i\_Port") = 6091 - 1 + $i;
				}
				$LocalWebPort = defined $cfg->param("MSI.Musicserver$i\_LocalWebPort") ? $cfg->param("MSI.Musicserver$i\_LocalWebPort") : 6091-1+$i;
								
				my %fms : shared;
				#LOGINF "MSI $i IP " . $cfg->param("MSI.Musicserver$i\_Ip") . " PORT " . $cfg->param("MSI.Musicserver$i\_Port");
				LOGINF "MSI $i LocalWebPort " . $cfg->param("MSI.Musicserver$i\_LocalWebPort");
				
				# $msi_servers{ $i } = $cfg->param("MSI.Musicserver$i\_Ip") . ":" . $cfg->param("MSI.Musicserver$i\_Port");
				$fms{host} = $cfg->param("MSI.Musicserver$i\_Ip") . ":" . $cfg->param("MSI.Musicserver$i\_Port");
				$fms{LocalWebPort} = $LocalWebPort;
				
				my %fmszone : shared;
				my %fmsplayer : shared;
				for ( my $ii=1; $ii<=30; $ii++ ) { # 30 Zones max
					if ( $cfg->param("MSI.Musicserver$i\_Z$ii") ) {
						#$msi_zones{ $cfg->param("MSI.Musicserver$i\_Z$ii") } = $ii;
						#$msi_players{ $cfg->param("MSI.Musicserver$i\_Z$ii") } = $i;
						LOGINF "MSI ZONE $ii PLAYER " . $cfg->param("MSI.Musicserver$i\_Z$ii");
						$fmszone{$ii} = $cfg->param("MSI.Musicserver$i\_Z$ii");
						$fmsplayer{$cfg->param("MSI.Musicserver$i\_Z$ii")} = $ii;
					}
				}
				$fms{zone} = \%fmszone;
				$fms{player} = \%fmsplayer;
				$msi_servers{$i} = \%fms;
			}
		}
	}
	
	# Read volumes from config
	if( $cfg->param("LMSTTS.tts_lmsvol") ) { $tts_lmsvol = $cfg->param("LMSTTS.tts_lmsvol"); }
	if( $cfg->param("LMSTTS.tts_minvol") ) { $tts_minvol = $cfg->param("LMSTTS.tts_minvol"); }
	if( $cfg->param("LMSTTS.tts_maxvol") ) { $tts_maxvol = $cfg->param("LMSTTS.tts_maxvol"); }
	LOGINF "TTS volumes from config: $tts_lmsvol, $tts_minvol, $tts_maxvol";
	
	# Labels
	$mode_string{-3} = $cfg->param("LMS2UDP.ZONELABEL_Disconnected");
	$mode_string{-2} = $cfg->param("LMS2UDP.ZONELABEL_Poweredoff");
	$mode_string{-1} = $cfg->param("LMS2UDP.ZONELABEL_Stopped");
	$mode_string{0}  = $cfg->param("LMS2UDP.ZONELABEL_Paused");
	$mode_string{1}  = $cfg->param("LMS2UDP.ZONELABEL_Playing");

	if(! is_enabled($lms2udp_activated) && ! $option_activate) {	
		LOGOK "Squeezelite Player Plugin LMS2UDP is NOT activated in config file. That's ok. Terminating.";
		LOGTITLE "LMS Gateway stopped (disabled)";
		unlink $pidfile;
		exit(0);
	}

	if (is_enabled($lms2udp_usehttpfortext) || (! $lms2udp_usehttpfortext) || ($lms2udp_usehttpfortext eq "")) {
		$lms2udp_usehttpfortext = 1; }
	else {
		$lms2udp_usehttpfortext = undef;
	}

	# Init default values if empty
	if (! $squ_lmswebport) { $squ_lmswebport = 9000; }
	if (! $squ_lmscliport) { $squ_lmscliport = 9090; }
	if (! $lms2udp_berrytcpport) { $lms2udp_berrytcpport = 9092; }
	if (! $lms2udp_udpport) { $lms2udp_udpport = 9093; }
	if (! $lms2udp_forcepolldelay) { $lms2udp_forcepolldelay = 300; }
	if (! $lms2udp_refreshdelayms || $lms2udp_refreshdelayms < 30) { $lms2udp_refreshdelayms = 150; }
	if (!defined $sendtoms || $sendtoms eq "1") { $sendtoms = 1; } else { $sendtoms = undef;}
	LOGWARN "Sending to Miniserver is DISABLED (sendToMS=0)" if (!$sendtoms);
	LOGINF "Sending to Miniserver is ENABLED" if ($sendtoms);

	# Miniserver data
	my %miniservers = LoxBerry::System::get_miniservers();
	if(! $miniservers{$lms2udp_msnr}) {
		LOGCRIT "Configured Miniserver $lms2udp_msnr does not exist. Check your Miniservers in the LoxBerry Miniserver widget and your plugin configuration.";
		exit(1);
	}

	# my $miniserver = $lms2udp_msnr;
	$miniserverip        = $miniservers{$lms2udp_msnr}{IPAddress};
	$miniserverport      = $miniservers{$lms2udp_msnr}{Port};
	$miniserveradmin     = $miniservers{$lms2udp_msnr}{Admin};
	$miniserverpass      = $miniservers{$lms2udp_msnr}{Pass};
	LOGINF "MSIP $miniserverip MSPORT $miniserverport LMS $squ_server\n";

}




##########################
# Thread

sub testthread 
{
	my ($player) = @_;
	print STDERR "THREAD STARTED =========================================";
	print STDERR "Player $player is " . $playerstates{$player}->{Name} . "\n";


}




## Termination handling
$SIG{INT} = sub { 
	if($log) {
		$log->default();
		LOGOK("LMS2UDP interrupted by Ctrl-C"); 
		LOGTITLE("LMS2UDP interrupted by Ctrl-C"); 
		LOGEND("lms2udp.pl ended");
	}
	exit 1;
};

$SIG{TERM} = sub { 
	if($log) {
		$log->default();
		LOGOK("LMS2UDP requested to stop"); 
		LOGTITLE("LMS2UDP requested to stop"); 
		LOGEND;
	}
	exit 1;	
};

