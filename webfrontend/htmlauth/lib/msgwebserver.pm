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
# FMS1_Activated=True
# FMS1_LocalWebPort=8091
# FMS1_MSGWebHost=192.168.3.22
# FMS1_MSGWebPort=8090
# FMS1_Player_Z1=c4:32:5e:e7:32:39
# FMS1_Player_Z2=aa:aa:85:38:be:18
# FMS1_Player_Z3=b8:27:eb:b4:1d:8d
# FMS1_Player_Z4=aa:aa:84:bf:25:07
# FMS1_Player_Z5=74:da:38:05:07:66
# FMS1_Player_Z6=3d:a9:8d:0d:e3:88
#
# Up to 30 zones per Music server are supported
#
# Install MSG Plugin somewhere and point it to this IP to port 8091
# https://github.com/mjesun/loxberry-music-server-gateway
#
use JSON::PP;
use Mojolicious::Lite;
use LoxBerry::Log;
use Switch;
use strict;
use warnings;

#our @msgweb_thr : shared; # List of MSGWeb threads (for multiple Musicservers)
my $version = "1.0.6.2";
my $lmscommand;
my $fl; # is the log object
my $fms;
my $playerstates;

# Starting routine for the threads
# Parameter is fmsid as number (1,2,....) like in the config file
sub start_fmsweb 
{
	
	my ($fmsid) = @_;
	
	# Create a logging object
	$fl = LoxBerry::Log->new (
		name => "msgwebserver $fmsid",
		filename => $LoxBerry::System::lbplogdir."/msgwebserver_$fmsid.log",
		addtime => 1,
		append => 1,
		stdout => 1,
		loglevel => 7
	);

	$fl->LOGSTART("Thread MSGSERVER $fmsid started (PID $$)");
	$fl->DEB("$$ This is $0 Version $version");

	
	# From now on, $fms is the hashref to the actual MSG server and it's config
	$fms = $main::msg_servers{$fmsid};
	# e.g. $fms->{host} is the host:port

	$fl->INF("$$ This webserver runs for Fake Musicserver (FMS) $fmsid on port " . $fms->{LocalWebPort});

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

		# Define playerstates here because we have to modify the state below to 
		# sync the Loxone WebGUI 
		$playerstates = \%main::playerstates; 

		switch ($command) {
			case 'play'  { 
				$lmscommand = "play";
				$playerstates->{$player}->{Mode} = 1;
			}
			case 'resume' { 
				$lmscommand = "play";
				$playerstates->{$player}->{Mode} = 1;
			}
			case 'stop' { 
				$lmscommand = "stop";
				$playerstates->{$player}->{Mode} = 0;
			}
			case 'pause' { 
				$lmscommand = "pause";
				$playerstates->{$player}->{Mode} = 0;
			}
			case 'shuffle' { 
				$lmscommand = "playlist shuffle $value";
				$playerstates->{$player}->{Shuffle} = $value;
			}
			case 'repeat' { 
				$lmscommand = "playlist repeat $value";
				$playerstates->{$player}->{Repeat} = $value;
			}
			case 'volume' { 
				$lmscommand = "mixer volume $value";
				$playerstates->{$player}->{Volume} = $value;
			}
		}

		# Send to LMS tcp queue
		# The queue is managed by the main thread
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

		# Check peer information
		my $address = $c->tx->remote_address;
		my $port    = $c->tx->remote_port;
		
		$fl->DEB("Request from $address\:$port");

		# Read Player States and create output
		my $state = &create_state($zone);
		
		# Render in UTF8
		utf8::decode($state);
		utf8::decode($state);
		$c->res->headers->header('Content-Type' => 'application/json');
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

	if (! $playerstates ) {
		$playerstates = \%main::playerstates; 
		# KISS (copy the ref to not need the write the main:: package qualifier
		# $playerstates is not a copy of data. It is the actual state of lms2udp
		$fl->DEB("create_state: playerstates not yet defined. Will read them from main::playerstates");
	}

	$fl->DEB("Creating State for Player " . $player);

	if( !zone_available($zone) ) {
		$fl->ERR("Zone $zone does not match to a valid player mac in LMS");
		return;
	}
	
	# Recalculate Mode
	my $mode;
	if ( $playerstates->{$player}->{Mode} eq "-1" ) { $mode = "stop"; }
	elsif ( $playerstates->{$player}->{Mode} eq "0" ) { $mode = "pause"; }
	elsif ( $playerstates->{$player}->{Mode} eq "1" ) { $mode = "play"; }
	else { $mode = "buffer"; }

	$fl->DEB("Mode is " . $playerstates->{$player}->{Mode});
	
	# Create json
	my %response = (
		'player' => {
			'id' => $player,
			'mode' => $mode,
			'time' => int($playerstates->{$player}->{time_fuzzy}*1000),
			'volume' => $playerstates->{$player}->{volume},
			'repeat' => $playerstates->{$player}->{Repeat},
			'shuffle' => $playerstates->{$player}->{Shuffle}
		},
		'track' => {
			'title' => $playerstates->{$player}->{Songtitle},
			'album' => $playerstates->{$player}->{Album},
			'id' => $player,
			'artist' => $playerstates->{$player}->{Artist},
			'duration' => int($playerstates->{$player}->{Duration}*1000),
			'image' => $playerstates->{$player}->{Cover}
		}
	);
	undef $playerstates;

	#$fl->DEB("Response state data:\n" . Data::Dumper::Dumper(\%response)); 
	my $jsonresponse = JSON::PP::encode_json(\%response);

	return($jsonresponse);

}

# Checks if the requested zone has an available mac defined
# Parameter is zone number
sub zone_available
{
	my ($zone) = @_;
	if (!defined $zone) {
		$fl->WARN("zone_available: zone parameter missing or empty");
		return;
	}
	
	#$fl->DEB(Data::Dumper::Dumper($fms));
	
	my $player = $fms->{zone}->{$zone};
	if (!$player) {
		$fl->WARN("zone_available: zone $zone has no player defined");
		return;
	}
	
	#$fl->DEB("Playerstates:\n" . Data::Dumper::Dumper(\%main::playerstates));
	
	
	if( !defined $main::playerstates{$player} ) {
		$fl->WARN("zone_available: player $player is not a valid player in LMS");
		return;
	}

	$fl->OK("zone_available: Zone $zone is player $player (" . $main::playerstates{$player}->{Name} . ")");
	return 1;
	
}


sub start_msgthreads
{
	$main::log->INF("Entering start_msgthreads");
	$main::log->DEB("FMS configuration:\n" . Data::Dumper::Dumper(\%main::msg_servers));
	foreach my $key ( keys %main::msg_servers ) {
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
