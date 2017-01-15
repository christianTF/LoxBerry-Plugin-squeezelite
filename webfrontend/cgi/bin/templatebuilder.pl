#!/usr/bin/perl
# Christian Fenzl, christiantf@gmx.at 2017
# This program creates Loxone Virtual In templates for a selected Logitech Media Server Zone.

use strict;

use IO::Socket;
use IO::Socket::Timeout;
use URI::Escape;
use POSIX qw/ strftime /;
use HTML::Entities;
use Config::Simple;
use Time::HiRes qw(usleep);
use Switch;

our $tcpout_sock;
our %playerstates;
our @rawparts;
our @parts;
our $line;
my $xmlout;

our $cfg = new Config::Simple("tcp2udp.cfg");

# This is host and port of the remote machine we are communicating with.
my $tcpout_host = 'homews';
my $tcpout_port = 9090;
my $udpout_port = 5000;
my $loxberry_ip = "1.2.3.4";

# Connection to the remote TCP host
$tcpout_sock = create_out_socket($tcpout_sock, $tcpout_port, 'tcp', $tcpout_host);
# No socket, no fun. Exit.
if (! $tcpout_sock->connected) {
	exit(1);
}
print $tcpout_sock "players 0\n";
$line = $tcpout_sock->getline;
# Nothing happened - exit!
if (! $line) {
	exit(1);
}
chomp $line;
	
@rawparts = split(/ /, $line);
@parts = split(/ /, $line);
foreach my $part (@parts) {
	$part = uri_unescape($part);
}
if (! players()) {
	# Nothing found;
	exit(1);
}

$xmlout =  "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
$xmlout .= "<VirtualInUdp Title=\"Logitech Media Server\" Comment=\"by LoxBerry Squeezeplayer Plugin\" Address=\"$loxberry_ip\" Port=\"$udpout_port\">\n";

   foreach my $player (sort(keys %playerstates)) {
        #print $player, '=', $playerstates{$player}{name}, "\n";
		#print $player, '=', $playerstates{$player}{ip}, "\n";
		$xmlout .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name}_shuffle\" Comment=\"$playerstates{$player}{name} Zufallswiedergabe\" Address=\"\" Check=\"$player playlist shuffle \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"2\"/>\n";
		$xmlout .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name}_repeat\" Comment=\"$playerstates{$player}{name} Wiederholung\" Address=\"\" Check=\"$player playlist repeat \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"2\"/>\n";
		$xmlout .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name}_stream\" Comment=\"$playerstates{$player}{name} ist Stream\" Address=\"\" Check=\"$player is_stream \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlout .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name}_mode_value\" Comment=\"$playerstates{$player}{name} Modus\" Address=\"\" Check=\"$player mode_value \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlout .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name}_volume\" Comment=\"$playerstates{$player}{name} Lautstärke\" Address=\"\" Check=\"$player mixer volume \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"100\"/>\n";
		$xmlout .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name}_muting\" Comment=\"$playerstates{$player}{name} stumm\" Address=\"\" Check=\"$player mixer muting \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlout .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name}_connected\" Comment=\"$playerstates{$player}{name} verbunden\" Address=\"\" Check=\"$player connected \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
	}

$xmlout .= "</VirtualInUdp>\n";

print $xmlout;
	
sub players
{
	my $curr_player;
	my $colon;
	my $tagname;
	my $tagvalue;
	my $playercount=0;
	
	for my $partnr (0 .. $#parts) {
		$colon = index ($parts[$partnr], ':');
		if ($colon < 1) { 
			next;
		}
		$tagname = substr($parts[$partnr], 0, $colon);
		$tagvalue = substr($parts[$partnr], $colon+1);
		if ($tagname eq 'playerid') {
			$curr_player = $tagvalue;
			$playercount++;
			# print "DEBUG: ######### CurPlayer #$curr_player# ############\n";
			next;
		} elsif ($curr_player) {
			switch ($tagname) {
				case 'name' 		{ $playerstates{$curr_player}{name} = $tagvalue; next; }
				case 'connected'	{ $playerstates{$curr_player}{connected} = $tagvalue; next; }
				case 'ip'	{ $playerstates{$curr_player}{ip} = (split(/:/, $tagvalue))[0]; next; }
				case 'connected'	{ $playerstates{$curr_player}{connected} = $tagvalue; next; }
			}
		}
	}
	if (! $curr_player) {
		return undef;
	} else {
		return $playercount;
	}
}

	
	

	

#################################################################################
# Create Out Socket
# Params: $socket, $port, $proto (tcp, udp), $remotehost
# Returns: $socket
# This one is blocking!
#################################################################################

sub create_out_socket 
{
	my ($socket, $port, $proto, $remotehost) = @_;
	
	my %params = (
		PeerHost  => $remotehost,
		PeerPort  => $port,
		Proto     => $proto,
		Blocking  => 1
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
		# print STDERR "Created $proto out socket to $remotehost on port $port\n";
	} else {
		# print STDERR "WARNING: Socket to $remotehost on port $port seems to be offline - will retry\n";
	}
	IO::Socket::Timeout->enable_timeouts_on($socket);
	$socket->read_timeout(5);
	$socket->write_timeout(5);
	return $socket;
}
