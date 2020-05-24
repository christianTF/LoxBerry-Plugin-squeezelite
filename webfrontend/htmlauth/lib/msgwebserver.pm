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
	require Clone;
	
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

		# Check peer information
		my $address = $c->tx->remote_address;
		my $port    = $c->tx->remote_port;
		
		$fl->DEB("Received /zone/$zone/$command/$value request from $address\:$port");

		# Define playerstates here because we have to modify the state below to 
		# sync the Loxone WebGUI 
		$playerstates = Clone::clone(\%main::playerstates);
		# $playerstates = \%main::playerstates; 

		switch ($command) {
			case 'play'  { 
				$lmscommand = "play";
				$playerstates->{$player}->{Mode} = 1;
			}
			case 'resume' { 
				$lmscommand = "pause 0";
				$playerstates->{$player}->{Mode} = 1;
			}
			case 'stop' { 
				$lmscommand = "stop";
				$playerstates->{$player}->{Mode} = 0;
			}
			case 'pause' { 
				$lmscommand = "pause 1";
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
			case 'next' { 
				$lmscommand = "playlist index +1";
			}
			case 'previous' { 
				$lmscommand = "playlist index -1";
			}
			case 'time' { 
				$lmscommand = "time $value";
				$playerstates->{$player}->{time} = $value;
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
		
		$fl->DEB("Received /zone/$zone/state request from $address\:$port");
		# Read Player States and create output
		my $state = &create_state($zone);
		
		# Render in UTF8
		utf8::decode($state);
		utf8::decode($state);
		$c->res->headers->header('Content-Type' => 'application/json');
		$c->render(text => $state);

	};

	# Answer with global Favorites
	get '/favorites/0' => sub {

		my $c = shift;
		#my $zone = $c->stash('zone');

		# Check peer information
		my $address = $c->tx->remote_address;
		my $port    = $c->tx->remote_port;
		
		$fl->DEB("Received favorites/0 from $address\:$port");

		# Read global favorites from LMS
		my $lmsfavs = &create_fav();
		
		# Render in UTF8
		#utf8::decode($state);
		#utf8::decode($state);
		#$c->res->headers->header('Content-Type' => 'application/json');
		#$c->render(text => $state);

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

	$fl->DEB("create_state called");

	my $zone = shift;
	my $player = $fms->{zone}->{$zone};

	if (! $playerstates ) {
		$playerstates = Clone::clone(\%main::playerstates);
		$fl->DEB("create_state: playerstates not yet defined. Will read them from main::playerstates");
	}

	$fl->DEB("Creating state for player " . $player);

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

#
# Create Favorites
#
sub create_fav {
	
	$fl->DEB("create_fav called");

	my $zone = shift;
	my $player;

	# If no player is specified, grab global favs
	if (!$zone) {
		my $player = "XX:XX:XX:XX:XX:XX";
	} else {
		my $player = $fms->{zone}->{$zone};
	}

	$fl->DEB("Grabbing favorites for player " . $player);

	#if( !zone_available($zone) ) {
	#	$fl->ERR("Zone $zone does not match to a valid player mac in LMS");
	#	return;
	#}
	
	# Grab favorites from LMS
	my $lmsresp = &get_lmsdata($player, '{"id":1,"method":"slim.request","params":["XX:XX:XX:XX:XX:XX", ["favorites","items",0,10,"menu:favorites","useContextMenu:1"]]}');

	$fl->DEB("Response fav lms data:\n" . Data::Dumper::Dumper($lmsresp)); 
	
	# Create json
	#my %response = (
	#	'player' => {
	#		'id' => $player,
	#		'mode' => $mode,
	#		'time' => int($playerstates->{$player}->{time_fuzzy}*1000),
	#		'volume' => $playerstates->{$player}->{volume},
	#		'repeat' => $playerstates->{$player}->{Repeat},
	#		'shuffle' => $playerstates->{$player}->{Shuffle}
	#	},
	#	'track' => {
	#		'title' => $playerstates->{$player}->{Songtitle},
	#		'album' => $playerstates->{$player}->{Album},
	#		'id' => $player,
	#		'artist' => $playerstates->{$player}->{Artist},
	#		'duration' => int($playerstates->{$player}->{Duration}*1000),
	#		'image' => $playerstates->{$player}->{Cover}
	#	}
	#);
	#undef $playerstates;


	#my $jsonresponse = JSON::PP::encode_json(\%response);
	my $jsonresponse = "";

	return($jsonresponse);

}

#
# Grab data from LMS in JSON format
#
sub get_lmsdata {

	$fl->DEB("get_lmsdata called");

	use WWW::Curl::Easy;
	my ($player,$request) = @_;
	
	if (@_ != 2) {
		$fl->WARN("get_lmsdata: odd number of parameters");
		return;
	}
	
	# This is an example for grabbing data from the commandline using curl
	# curl -s -H "Content-Type: application/json" -X POST -d '{"id":1,"method":"slim.request","params":["XX:XX:XX:XX:XX:XX", \\
	# ["favorites","items",0,10,"menu:favorites","useContextMenu:1"]]}' \\
	# http://localhost:9000/jsonrpc.js | jq

	my $curl = WWW::Curl::Easy->new;
	$curl->setopt(WWW::Curl::Easy::CURLOPT_NOPROGRESS, 1);
	$curl->setopt(WWW::Curl::Easy::CURLOPT_HEADER, 0); # don't include headers in body
	my @headers  = ("Content-Type: application/json");
	$curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER, \@headers);
	$curl->setopt(WWW::Curl::Easy::CURLOPT_ENCODING, 'gzip');
	$curl->setopt(WWW::Curl::Easy::CURLOPT_POST, 1);
	# This is the request which should be send to LMS
	$curl->setopt(WWW::Curl::Easy::CURLOPT_POSTFIELDS, $request );
	
	# either of the following speeds curl up massively
	$curl->setopt(WWW::Curl::Easy::CURLOPT_TCP_NODELAY, 1);
	#$curl->setopt(CURLOPT_FORBID_REUSE, 1);

	# A filehandle, reference to a scalar or reference to a typeglob can be used here.
	my $response_body;
	$curl->setopt(WWW::Curl::Easy::CURLOPT_WRITEDATA,\$response_body);
	
	# Starts the actual request
	$curl->setopt(WWW::Curl::Easy::CURLOPT_URL, "http://" . $main::squ_server . ":" . $main::squ_lmswebport . "/jsonrpc.js");
	my $retcode = $curl->perform;
 
	# Looking at the results...
	if ($retcode != 0) {
        	$fl->ERR("An error happened: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf);
		return;
	}
	$fl->DEB("Request successfull");

	return ( $curl->getinfo(WWW::Curl::Easy::CURLINFO_HTTP_CODE) );

}

# Checks if the requested zone has an available mac defined
# Parameter is zone number
sub zone_available
{
	$fl->DEB("zone_available called");

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
