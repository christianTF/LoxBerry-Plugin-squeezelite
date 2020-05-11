#!/usr/bin/perl

package MSGWEB;

# This is a webserver to serve and receive commands for the MSG Gateway
# (Musicserver Gateway)
#
# Config file ~/config/plugins/squeezelite/plugin_squeezelite.cfg
# needs following instance:
#
# [MSG]
# Activated=True
# Musicserver1_Port=8091
# Musicserver1_Z1=c4:32:5e:e7:32:39
# Musicserver1_Z3=b8:27:eb:b4:1d:8d
# Musicserver1_Z4=aa:aa:84:bf:25:07
# Musicserver1_Z5=74:da:38:05:07:66
# Musicserver1_Z6=3d:a9:8d:0d:e3:88
#
# Up to 30 zones per Music server are supported
#
# Install MSG Plugin and point it to this IP to port 8091
#
# Start the webserver with:
#
# ./msgwebserver.pl --ms=1 --verbose
#
# where ms is the number of your music server
#
use Mojolicious::Lite;
use LoxBerry::Log;
use Switch;
use strict;
use warnings;

#our @msgweb_thr : shared; # List of MSGWeb threads (for multiple Musicservers)
my $version = "1.0.6.1";
my $lmscommand;
my $fl; # is the log object
my $fms;

# Starting routine for the threads
# Parameter is fmsid as number (1,2,....) like in the config file
sub start_fmsweb 
{
	
	my ($fmsid) = @_;
	
	# Create a logging object
	$fl = LoxBerry::Log->new (
		name => "msgwebserver $fmsid",
		addtime => 1,
		append => 1,
		stdout => 1,
		loglevel => 7
	);

	$fl->LOGSTART("Thread MSGSERVER $fmsid started (PID $$)");
	$fl->DEB("$$ This is $0 Version $version");

	
	# From now on, $fms is the hashref to the actual MSG server and it's config
	$fms = $main::msi_servers{$fmsid};
	# e.g. $fms->{host} is the host:port

	# # Creating pid
	# my $pidfile = "/run/shm/msgwebserver.$$";
	# open(my $fh, '>', $pidfile);
	# print $fh "$$";
	# close $fh;
	# $fl->DEB("$$ My PID is: $$");

	$fl->INF("$$ This webserver runs for Musicserver $fmsid on port " . $fms->{LocalWebPort});

	# # Read config
	# my $cfgfilename = "$lbpconfigdir/plugin_squeezelite.cfg";
	# read_config();

	###############################################
	## Definition of incoming requests
	###############################################

	#
	# Anwser requests
	#
	post '/zone/:zone/:command/:value' => {zone => '0', command => '0', value => '0'} => sub {

		my $c = shift;
		my $zone = $c->stash('zone');
		my $command = $c->stash('command');
		my $value = $c->stash('value');
		my $player = $fms->{zone}->{$zone};
		
		$fl->DEB("Received COMMAND $command $value for ZONE $zone");

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

		#
		# Send to LMS tcp queue
		# The queue is managed by the main thread
		#
		# print $tcpout_sock "$player $lmscommand\n";
		
		{
			# During lock, other threads will wait for release 
			threads::shared::lock(@main::tcpout_queue);
			push @main::tcpout_queue, "$player $lmscommand\n";
			# Lock is released automatically after leaving the scope of the block
		}
	
		
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
	# Start server
	#

	#app->start;
	app->start('daemon', '-l', "http://*:".$fms->{LocalWebPort});

}

#
# Create Player State
#
sub create_state {

	$fl->DEB("Sub create_state");

	my $zone = shift;
	my $player = $fms->{zone}->{$zone};

	my $playerstates = $main::playerstates; 
	# KISS (copy the ref to not need the write the main:: package qualifier
	# $playerstates is not a copy of data. It is the actual state of lms2udp
	
	# &read_states();

	$fl->DEB("Zone is $zone, Player is $player");
	
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
			time => $playerstates->{$player}->{time_fuzzy}*1000,
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

	# CF: Zugriff auf die Daten direkt mittels $playerstates->{$mac}->{...Attribut...}

	$fl->DEB("Sub read_states - OBSOLETE");
	# my $jsonobj = LoxBerry::JSON->new();
	# my $data = $jsonobj->open(filename => $datafile, readonly => 1);
	# $playerstates = $data->{'States'};
	return (1);
}

#
# Change states in tmpfs datafile (created by lms2udp.pl)
# 
sub change_state {

	# CF: Weiß nicht genau, wofür das ist?


	$fl->DEB("Sub change_state");
	# my $player = shift;
	# my $key = shift;
	# my $value = shift;

	# $fl->INF("State of $player changed: $key is now $value");

	# my $jsonobj = LoxBerry::JSON->new();
	# my $data = $jsonobj->open(filename => $datafile, readonly => 0);
	# $data->{States}->{$player}->{$key} = $value;
	# my $saved = $jsonobj->write();
	# return (1);

}

# #
# # Read plugin config
# #
# sub read_config {

	# # Check existance of config file
	# if (! (-e $cfgfilename)) {
		# LOGCRIT "Squeezelite Player Plugin MSGWEBSERVER configuration does not exist. Terminating.\n";
		# LOGTITLE "MSG Webserver stopped (no configuration)";
		# unlink $pidfile;
		# exit(0);
	# }
	
	# $fl->INF("Reading Plugin config $cfgfilename");
		
	# # Read the Plugin config file 
	# $cfg = new Config::Simple($cfgfilename);

	# # guest port of lms2udp
	# $berrytcpport = $cfg->param("LMS2UDP.berrytcpport");
	# if (!$berrytcpport) { $berrytcpport = 9092; };

	# # Read MSI config from config
	# $fmsid_activated = $cfg->param("MSG.Activated");
	# if ( $fmsid_activated ) {
		# $fl->INF "MSG is ENABLED";
		# $port = $cfg->param("MSG.Musicserver$fmsid\_Port");
		# if (!$port) {$port = "8091"};
		# for ( my $i=1; $i<=30; $i++ ) { # 30 Zones max
			# if ( $cfg->param("MSG.Musicserver$fmsid\_Z$i") ) {
				# $fmsid_players{ $i } = $cfg->param("MSG.Musicserver$fmsid\_Z$i");
				# $fl->INF "MSG ZONE $i is PLAYER " . $cfg->param("MSG.Musicserver$fmsid\_Z$i");
			# }
		# }
	# }

# }

#
# Create Out Socket
# Params: $socket, $port, $proto (tcp, udp), $remotehost
# Returns: $socket
#
# sub create_out_socket 
# {
	# my ($socket, $port, $proto, $remotehost) = @_;
	
	# my %params = (
		# PeerHost  => $remotehost,
		# PeerPort  => $port,
		# Proto     => $proto,
		# Blocking  => 0
	# );
	
	# if ($proto eq 'tcp') {
		# $params{'Type'} = SOCK_STREAM;
	# } elsif ($proto eq 'udp') {
		# # $params{'LocalAddr'} = 'localhost';
	# }
	# if($socket) {
		# close($socket);
	# }
		
	# $socket = IO::Socket::INET->new( %params )
		# or die "Couldn't connect to $remotehost:$port : $@\n";
	# sleep (0.02);
	# if ($socket->connected) {
		# $fl->OK("Created $proto out socket to $remotehost on port $port");
	# } else {
		# $fl->WARN("Socket to $remotehost on port $port seems to be offline - will retry");
	# }
	# IO::Socket::Timeout->enable_timeouts_on($socket);
	# $socket->read_timeout(2);
	# $socket->write_timeout(2);
	# return $socket;
# }


sub start_msgthreads
{
	$main::log->INF("Entering start_msgthreads");
	$main::log->DEB("FMS configuration:\n" . Data::Dumper::Dumper(\%main::msi_servers));
	foreach my $key ( keys %main::msi_servers ) {
		$main::log->INF("Trying to start webserver $key");
		my $thr = threads->create('MSGWEB::start_fmsweb', $key);
		$main::log->OK("MSGWEB: Created MSGWEB $key thread with thread id " . $thr->tid());
		$main::threads{$thr->tid()} = $thr->tid();
	}
	
}



#####################################################
# Finally 1; ########################################
#####################################################
1;
