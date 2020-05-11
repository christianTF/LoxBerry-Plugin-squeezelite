#!/usr/bin/perl
use Mojolicious::Lite;
use LoxBerry::Log;
use LoxBerry::System;
use LoxBerry::JSON;
use IO::Select;
use IO::Socket;
use IO::Socket::Timeout;
use Switch;
#use Data::Dumper;
use Getopt::Long qw(GetOptions);
#use URI::Escape;
use strict;
use warnings;

# Config parameters
my $version = "1.0.6";
my $log;
my $datafile = "/dev/shm/lms2udp_data.json";
my $playerstates;
my $cfg;
my $debug;
my $msg_activated;
my %msg_servers;
my %msg_zones;
my %msg_players;
my $port;
my $ms;
my $tcpout_sock;
my $berrytcpport;
my $lmscommand;

# Termination handling
$SIG{INT} = sub { 

	if($log) {
		$log->default();
		LOGOK("MSGWEBSERVER interrupted by Ctrl-C"); 
		LOGTITLE("MSGWEBSERVER interrupted by Ctrl-C"); 
		LOGEND("msgwebserver.pl ended");
	}
	exit 1;

};

$SIG{TERM} = sub { 

	if($log) {
		$log->default();
		LOGOK("MSGWEBSERVER requested to stop"); 
		LOGTITLE("MSGWEBSERVER requested to stop"); 
		LOGEND;
	}
	exit 1;	

};

# Commandline options
my $verbose = '';

GetOptions ('verbose' => \$verbose,
            'ms=i' => \$ms,
            'quiet'   => sub { $verbose = 0 });
if (!$ms) {$ms = 1};

# Create a logging object
$log = LoxBerry::Log->new (
        name => "msgwebserver_$ms",
	addtime => 1,
);


# Due to a bug in the Logging routine, set the loglevel fix to 3
if ($verbose) {
        $log->stdout(1);
        $log->loglevel(7);
	$debug = 1;
}

LOGSTART("Daemon MSGWERVER $ms started");
LOGDEB "This is $0 Version $version";

# Creating pid
my $pidfile = "/run/shm/msgwebserver.$$";
open(my $fh, '>', $pidfile);
print $fh "$$";
close $fh;
LOGDEB "My PID is: $$";

LOGINF "This Webserver runs for Musicserver $ms";

# Read config
my $cfgfilename = "$lbpconfigdir/plugin_squeezelite.cfg";
read_config();

#
# Anwser requests
#
post '/zone/:zone/:command/:value' => {zone => '0', command => '0', value => '0'} => sub {

	my $c = shift;
	my $zone = $c->stash('zone');
	my $command = $c->stash('command');
	my $value = $c->stash('value');
	my $player = $msg_players{ $zone };

	#$tcpout_sock = create_out_socket($tcpout_sock, $berrytcpport, 'tcp', 'localhost');
	$tcpout_sock = create_out_socket($tcpout_sock, 9092, 'tcp', 'localhost');
	LOGDEB "Received COMMAND $command $value for ZONE $zone";

	switch ($command) {
		case 'play'  { 
			$lmscommand = "play";
			&change_state($player,'Mode','1');
		}
                case 'resume' { 
			$lmscommand = "play";
			&change_state($player,'Mode','1');
		}
                case 'stop' { 
			$lmscommand = "stop";
			&change_state($player,'Mode','0');
		}
                case 'pause' { 
			$lmscommand = "pause";
			&change_state($player,'Mode','0');
		}
                case 'shuffle' { 
			$lmscommand = "playlist shuffle $value";
			&change_state($player,'Shuffle',$value);
		}
                case 'repeat' { 
			$lmscommand = "playlist repeat $value";
			&change_state($player,'Repeat',$value);
		}
        }

	# Send to tcp guest queue
	print $tcpout_sock "$player $lmscommand\n";
	
	# Read Player States and create output
	my $state = &create_state($zone);
	
	# Render in UTF8
	utf8::decode($state);
	$c->render(text => $state);



};

# Answer with player/track state
get '/zone/:zone/state' => sub {

	my $c = shift;
	my $zone = $c->stash('zone');

	# Read Player States and create output
	my $state = &create_state($zone);

	# Render in UTF8
	utf8::decode($state);
	$c->render(text => $state);

};

#
# Create Player State
#
sub create_state {

	LOGDEB "Sub create_state";

	my $zone = shift;
	my $player = $msg_players{ $zone };
	&read_states();

	LOGDEB "Zone is $zone, Player is $player";
	
	# Recalculate Mode
	my $mode;
	if ( $playerstates->{$player}->{Mode} eq "-1" ) { $mode = "stop"; }
	elsif ( $playerstates->{$player}->{Mode} eq "0" ) { $mode = "pause"; }
	elsif ( $playerstates->{$player}->{Mode} eq "1" ) { $mode = "play"; }
	else { $mode = "buffer"; }

	# Create json
	my $json = to_json {
		player => {
			id => $player,
			mode => $mode,
			time => $playerstates->{$player}->{Time}*1000,
			volume => $playerstates->{$player}->{volume},
			repeat => $playerstates->{$player}->{Repeat},
			shuffle => $playerstates->{$player}->{Shuffle},
		},
		track => {
			id => $player,
			title => $playerstates->{$player}->{Songtitle},
			album => $playerstates->{$player}->{Album},
			artist => $playerstates->{$player}->{Artist},
			duration => $playerstates->{$player}->{Duration}*1000,
			image => $playerstates->{$player}->{Cover},
		}
	};

	return($json);

}

#
# Read states from tmpfs datafile (created by lms2udp.pl)
# 
sub read_states {

	LOGDEB "Sub read_states";
	my $jsonobj = LoxBerry::JSON->new();
	my $data = $jsonobj->open(filename => $datafile, readonly => 1);
	$playerstates = $data->{'States'};
	return (1);

}

#
# Change states in tmpfs datafile (created by lms2udp.pl)
# 
sub change_state {

	LOGDEB "Sub change_state";
	my $player = shift;
	my $key = shift;
	my $value = shift;

	LOGINF "State of $player changed: $key is now $value";

	my $jsonobj = LoxBerry::JSON->new();
	my $data = $jsonobj->open(filename => $datafile, readonly => 0);
	$data->{States}->{$player}->{$key} = $value;
	my $saved = $jsonobj->write();
	return (1);

}

#
# Read plugin config
#
sub read_config {

	# Check existance of config file
	if (! (-e $cfgfilename)) {
		LOGCRIT "Squeezelite Player Plugin MSGWEBSERVER configuration does not exist. Terminating.\n";
		LOGTITLE "MSG Webserver stopped (no configuration)";
		unlink $pidfile;
		exit(0);
	}
	
	LOGINF "Reading Plugin config $cfgfilename";
		
	# Read the Plugin config file 
	$cfg = new Config::Simple($cfgfilename);

	# guest port of lms2udp
	$berrytcpport = $cfg->param("LMS2UDP.berrytcpport");
	if (!$berrytcpport) { $berrytcpport = 9092; };

	# Read MSI config from config
	$msg_activated = $cfg->param("MSG.Activated");
	if ( $msg_activated ) {
		LOGINF "MSG is ENABLED";
		$port = $cfg->param("MSG.Musicserver$ms\_Port");
		if (!$port) {$port = "8091"};
		for ( my $i=1; $i<=30; $i++ ) { # 30 Zones max
			if ( $cfg->param("MSG.Musicserver$ms\_Z$i") ) {
				$msg_players{ $i } = $cfg->param("MSG.Musicserver$ms\_Z$i");
				LOGINF "MSG ZONE $i is PLAYER " . $cfg->param("MSG.Musicserver$ms\_Z$i");
			}
		}
	}

}

#
# Create Out Socket
# Params: $socket, $port, $proto (tcp, udp), $remotehost
# Returns: $socket
#
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

#
# Start server
#

#app->start;
app->start('daemon', '-l', "http://*:$port");
