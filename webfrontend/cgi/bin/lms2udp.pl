#!/usr/bin/perl
if (-d "REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/squeezelite/lib") {
	use lib 'REPLACEINSTALLFOLDER/webfrontend/cgi/plugins/squeezelite/lib';
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
our $version = "0.4.01";


# use strict;
# use warnings;

# Own modules

# Perl modules

use Config::Simple;
use Cwd 'abs_path';
use File::HomeDir;
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
# use TCPUDP;

my $home = "/opt/loxberry";
our $tcpin_sock;
our $tcpout_sock;
our $udpout_sock;
our $in_list;
our $out_list;
my $sel;
my $client;

our $line;
our $loopdivisor = 3;
our @rawparts;
our @parts;
our %playerstates;
# The playerstats hash uses the key PLAYERMAC
# It includes the following hash items
	# Known
	# Name
	# Connected
	# Songtitle
	# Artist
	# Power
	# Mode
	# Stream
	# Pause
	# Shuffle
	# Repeat
	# volume
	# treble
	# bass
	# sync (comma separated list of playerid's, or undef)

our %playerdiffs;
# This hash includes all changes since last UDP-Send

# Mode strings (will come from config later)

# Creating pid
my $pidfile = "/run/shm/lms2udp.$$";
open(my $fh, '>', $pidfile);
print $fh "$$";
close $fh;

# For debugging purposes, allow option --activate to override disabled setting in the config
my $option_activate;
GetOptions('activate' => \$option_activate) or die "Usage: $0 --activate to override config unactivate\n";

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

# Labels
our %mode_string;
$mode_string{-3} = $cfg->param("LMS2UDP.ZONELABEL_Disconnected");
$mode_string{-2} = $cfg->param("LMS2UDP.ZONELABEL_Poweredoff");
$mode_string{-1} = $cfg->param("LMS2UDP.ZONELABEL_Stopped");
$mode_string{0}  = $cfg->param("LMS2UDP.ZONELABEL_Paused");
$mode_string{1}  = $cfg->param("LMS2UDP.ZONELABEL_Playing");

if(! is_true($lms2udp_activated) && ! $option_activate) {	
	print STDERR "Squeezelite Player Plugin LMS2UDP is NOT activated in config file. That's ok. Terminating.\n";
	unlink $pidfile;
	exit(0);
}

if (is_true($lms2udp_usehttpfortext) || (! $lms2udp_usehttpfortext) || ($lms2udp_usehttpfortext eq "")) {
	$lms2udp_usehttpfortext = 1; }
else {
	$lms2udp_usehttpfortext = undef;
}

# Init default values if empty
if (! $squ_lmscliport) { $squ_lmscliport = 9090; }
if (! $lms2udp_berrytcpport) { $lms2udp_berrytcpport = 9092; }
if (! $lms2udp_udpport) { $lms2udp_udpport = 9093; }
if (! $lms2udp_forcepolldelay) { $lms2udp_forcepolldelay = 300; }
if (! $lms2udp_refreshdelayms || $lms2udp_refreshdelayms < 30) { $lms2udp_refreshdelayms = 150; }

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
					print "New guest connection accepted\n";
				} else {
					$guest->recv(my $guest_line, 1024);
					#my @guest_lines = $guest->getlines;
					#foreach my $guest_line (@guest_lines) {
						my $guest_answer;
						chomp $guest_line;
						print "GUEST: $guest_line\n";
						my @guest_params = split(/ /, $guest_line);
						print "GUEST_PARAMS[0]: $guest_params[0] \n";
						if (lc($guest_params[0]) eq 'lmsgtw') {
							print "GUEST-Param is lmsgtw - entering Plugin commands.\n";
							switch ($guest_params[1]) {
								case 'currstate' { $guest_answer = guest_currstate($guest_params[2]); }
							}
						print $guest $guest_answer;
						} else {
							print $tcpout_sock $guest_line;
							# We close the connection after that
						}
					#}	
					$in_list->remove($guest);
					$guest->close;
					$guest_lines = undef;
					
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
			print "Process line $input\n";
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
		
		# Let's send all the collected data to the Miniserver
		send_to_ms();
		
		# Here we sleep some time and start over again
		if ($input) {
			print "Fast response mode\n";
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
	print $udpout_sock "Hello Loxone, everything perpendicular on your flash drive ? ;-)\n";

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
		case 'title'	{ pupdate($parts[0], "Songtitle", $parts[2]);
						  print $tcpout_sock "$parts[0] artist ?\n$parts[0] remote ?\n";
						  return undef;}
		case 'artist'	{   pupdate($parts[0], "Songtitle", $playerstates{$parts[0]}{Songtitle});
							if(defined $parts[2]) {
								pupdate($parts[0], "Artist", $parts[2]);
							} else { 
								pupdate($parts[0], "Artist", undef);
							}
							return undef;
					}
		case 'power' 	{ # print "DEBUG: Power\n"; 
						  if ($rawparts[2] eq "0") {
							print $tcpout_sock "syncgroups ?\n";
							send_state (-2);
						} elsif ($rawparts[2] eq "1") {
							print $tcpout_sock "$rawparts[0] mode ?\n";
							print $tcpout_sock "syncgroups ?\n";
							pupdate($parts[0], "Power", 1);
							
						}
						return undef;
					}
		case 'mode'		{ 
					print "DEBUG: Mode |$rawparts[2]|$parts[2]|\n";
					if ($rawparts[2] eq 'stop') {
						if ($playerstates{$parts[0]}{Power} == 1) {
							send_state(-1);
						} else {
							send_state(-2);
						}
					} elsif ($rawparts[2] eq 'play') {
						pupdate($parts[0], "Mode", 1);
						send_state(1);
					} elsif ($rawparts[2] eq 'pause') {
						pupdate($parts[0], "Mode", 0);
						send_state(0);
					} else {
						pupdate($parts[0], "Mode", -2);
						send_state(-2);
					}
					return undef;
				}
		case 'client'	{ return client(); }
		case 'name'		{ pupdate($parts[0], "Name", $parts[2]); 
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
		case 'sync'		{ print $tcpout_sock "syncgroups ?\n"; 
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
					$playerstates{$parts[0]}{Songtitle} = $parts[3];
					$playerstates{$parts[0]}{Artist} = undef;
					# pupdate($parts[0], "Songtitle", $parts[3]);
					print $tcpout_sock "$rawparts[0] artist ?\n$rawparts[0] remote ?\n";
					send_state(1);
					return;
					#return "$parts[0] $parts[1] $parts[2] $parts[3]";
				} else { 
					pupdate($parts[0], "Stream", 1);
					pupdate($parts[0], "Songtitle", $parts[3]);
					print "DEBUG: Playlist thinks $parts[0] is a stream #$rawparts[4]#\n";
					send_state(1);
					return;
				}
			}	
		case 'title' {
					pupdate($parts[0], "Songtitle", $parts[3]);
					print $tcpout_sock "$rawparts[0] artist ?\n$rawparts[0] remote ?\n";
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
				return undef;
			}
		case 'stop' { print $tcpout_sock "$rawparts[0] mode ?\n";
					  #send_state(-1);
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

sub send_state 
{
	my ($state) = @_;
	switch ($state) {
		case -3		{ 	# Nicht verbunden
						pupdate($parts[0], "Mode", -3);
						pupdate($parts[0], "Title", undef);
						pupdate($parts[0], "Artist", undef);
						pupdate($parts[0], "Power", 0);
						pupdate($parts[0], "Pause", 0);
						pupdate($parts[0], "Connected", 0);
						pupdate($parts[0], "Known", 1);
					}
		case -2		{ 	# Zone ausgeschaltet
						pupdate($parts[0], "Mode", -2);
						pupdate($parts[0], "Title", undef);
						pupdate($parts[0], "Artist", undef);
						pupdate($parts[0], "Power", 0);
						pupdate($parts[0], "Pause", 0);
						pupdate($parts[0], "Connected", 1);
						pupdate($parts[0], "Known", 1);
					}
		case -1		{ 	# Zone gestoppt
						pupdate($parts[0], "Mode", -1);
						pupdate($parts[0], "Title", undef);
						pupdate($parts[0], "Artist", undef);
						pupdate($parts[0], "Power", 1);
						pupdate($parts[0], "Pause", 0);
						pupdate($parts[0], "Connected", 1);
						pupdate($parts[0], "Known", 1);
					}
		case 0		{ 	# Pause
						pupdate($parts[0], "Mode", 0);
						pupdate($parts[0], "Power", 1);
						pupdate($parts[0], "Pause", 1);
						pupdate($parts[0], "Connected", 1);
						pupdate($parts[0], "Known", 1);
					}
		case 1		{ 	# Play
						pupdate($parts[0], "Mode", 1);
						pupdate($parts[0], "Power", 1);
						pupdate($parts[0], "Pause", 0);
						pupdate($parts[0], "Connected", 1);
						pupdate($parts[0], "Known", 1);
					}
	}
}

sub client
{
	switch ($parts[2]) {
		case 'new'			{ print $tcpout_sock "$curr_player power ?\n$curr_player title ?\n$curr_player mixer volume ?\n$curr_player playlist shuffle ?\n$curr_player playlist repeat ?\n$curr_player mixer muting ?\n";
							  pupdate($parts[0], "Connected", 1);
							  pupdate($parts[0], "Known", 1);
							}
		case 'reconnect'	{ print $tcpout_sock "$curr_player power ?\n$curr_player title ?\n$curr_player mixer volume ?\n$curr_player playlist shuffle ?\n$curr_player playlist repeat ?\n$curr_player mixer muting ?\n"; 
							  pupdate($parts[0], "Connected", 1);
							  pupdate($parts[0], "Known", 1);
							}
							  
		case 'disconnect'	{ send_state(-3);
							  pupdate($parts[0], "Connected", 0);
							  pupdate($parts[0], "Known", 1);
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
			print $tcpout_sock "$curr_player power ?\n$curr_player title ?\n$curr_player mixer volume ?\n$curr_player playlist shuffle ?\n$curr_player playlist repeat ?\n$curr_player mixer muting ?\n";
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
	foreach $player (keys %playerstates) {
		if ($playerstates{$player}{sync}) {  
			pupdate($player, "sync", undef);
		}
	}
	
	# Nothing synced here
	if (! $rawparts[1]) {
		# print "DEBUG: Currently no syncgroups\n";
		return undef;
	}
	
	for my $groups (1 .. $#rawparts) {
		# print "Group $groups is $rawparts[$groups]\n";
		my ($key, $group) = split(/:/, uri_unescape($rawparts[$groups]), 2);
		if ($key eq "sync_members") {
			my @members = split(/,/, $group);
			foreach $member (@members) {
				if ($playerstates{$member}{sync} ne join(',', @members)) {
					pupdate($member, "sync", join(',', @members));
				}
			}
		} else { 
			next; 
		}
	}
}

sub pupdate 
{
	my ($player, $key, $value) = @_;
	$playerstates{$player}{$key} = $value;
	$playerdiffs{$player}{$key} = $value;
}

sub sync_pupdate 
{
	my $key = shift;
	my $value = shift;
	my $currplayer = shift;
	my @players = @_;
	
	foreach $player (@players) {
		if ($player eq $currplayer) {
			next;
		}
		pupdate($player, $key, $value);
	}
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
	
	$answer .= "-------------------------------------------------------\n";
	# If one player was requested
	if ($player) {
			$player = uri_unescape($player);
			$answer .= " Guest requested player state for $player $playerstates{$player}{Name}\n";
			if (! $playerstates{$player}) {
				$answer .= "  --> This player does not exist.";
			} else {
				foreach my $setting (keys %{$playerstates{$player} }) {
					$answer .= "$setting: $playerstates{$player}{$setting}\n";
				}
			}
		} else {
			# No player specified - list all
			foreach $player (sort keys %playerstates) {
				$answer .= "-------------------------------------------------------\n";
				$answer .= "Player $player $playerstates{$player}{Name}\n";
				foreach my $setting (keys %{$playerstates{$player} }) {
					$answer .= "$setting: $playerstates{$player}{$setting}\n";
				}
			}
		$answer .= "-------------------------------------------------------\n";
	}
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
	foreach $player (keys %playerdiffs) {
		my @members = split(/,/, $playerstates{$player}{sync});
		# Populate song title
		switch ($playerstates{$player}{Mode}) {
			case -3 	{ pupdate($player, "Songtitle", $mode_string{-3}); pupdate($player, "Artist", undef);}
			case -2 	{ pupdate($player, "Songtitle", $mode_string{-2}); pupdate($player, "Artist", undef);}
			case -1 	{ pupdate($player, "Songtitle", $mode_string{-1}); pupdate($player, "Artist", undef);}
		}
		# Populate to sync partners
		foreach my $setting (keys %{$playerdiffs{$player} }) {
			if (@members) {
				switch ($setting) {
					case 'Songtitle' 	{ sync_pupdate("Songtitle", $playerstates{$player}{$setting}, $player, @members); next;}
					case 'Artist' 		{ sync_pupdate("Artist", $playerstates{$player}{$setting}, $player, @members); next;}
					case 'Mode'			{ sync_pupdate("Mode", $playerstates{$player}{$setting}, $player, @members); next;}
					case 'Stream'		{ sync_pupdate("Stream", $playerstates{$player}{$setting}, $player, @members); next;}
					case 'Pause'		{ sync_pupdate("Pause", $playerstates{$player}{$setting}, $player, @members); next;}
					case 'Shuffle' 		{ sync_pupdate("Shuffle", $playerstates{$player}{$setting}, $player, @members); next;}
					case 'Repeat' 		{ sync_pupdate("Repeat", $playerstates{$player}{$setting}, $player, @members); next;}
				}
			}
		}
	}

	# Now we send the changes to MS
	my $udpout_string;
	foreach $player (keys %playerdiffs) {
		
		foreach my $setting (keys %{$playerdiffs{$player} }) {
		# Limit sending lenght to ~200
		if (length($udpout_string) > 200) {
				print $udpout_sock $udpout_string;
				print 
				"##  START SEND ######################################################\n" .
				$udpout_string .
				"## FINISHED SEND " . length($udpout_string) . "Bytes ###########################\n";
				print "Fast response mode\n";
				usleep($loopdelay/$loopdivisor);
				$udpout_string = undef;
			}
			switch ($setting) {
				case 'Songtitle' 
					{ 
					print "$player ARTIST: # " . $playerstates{$player}{Artist} . " # \n";
					
					my $title_artist;
						if ($playerstates{$player}{Artist} ne "") {
							$title_artist = "$playerstates{$player}{Songtitle} - $playerstates{$player}{Artist}";
						} else {
							$title_artist = "$playerstates{$player}{Songtitle}";
						}
					to_ms($player, "title", $title_artist);
					$udpout_string .= "$player playlist newsong $title_artist\n";
					next;
				}
				
				case 'Name'			{ to_ms($player, "name", $playerdiffs{$player}{$setting});
									  $udpout_string .= "$player name $playerdiffs{$player}{$setting}\n";
									  next;
									}
				case 'Mode'			{ to_ms($player, "mode", $mode_string{$playerdiffs{$player}{$setting}});
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
				case 'sync'			{ my $is_synced;
									  if ($playerdiffs{$player}{$setting}) {
										 $is_synced = 1;
									  } else { $is_synced = 0; }
									  $udpout_string .= "$player is_synced $is_synced\n"; next;}
				
				
			}
		}
	}
	if ($udpout_string) {
		print $udpout_sock $udpout_string;
		print 
		"##  START SEND ######################################################\n" .
		$udpout_string .
		"## FINISHED SEND " . length($udpout_string) . "Bytes ###########################\n";
	}
	%playerdiffs = undef;


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
	sleep (1);
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
	$url_nopass = "http://$miniserveradmin:*****\@$miniserverip\:$miniserverport/dev/sps/io/$player_label/$textenc";
	$ua = LWP::UserAgent->new;
	$ua->timeout(1);
	print "DEBUG: #$playerid# #$label# #$text#\n";
	print "DEBUG: -->URL $url_nopass\n";
	$response = $ua->get($url);
	return $response;
}
