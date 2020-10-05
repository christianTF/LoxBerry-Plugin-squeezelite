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
use Data::Dumper;

#our @msgweb_thr : shared; # List of MSGWeb threads (for multiple Musicservers)
my $version = "1.0.6.3";
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
	post '/zone/:zone/:command/*value' => {zone => '0', command => '0', value => '0'} => sub {

		my $c = shift;
		my $zone = $c->stash('zone');
		my $command = $c->stash('command');
		my $value = $c->stash('value');
		my $player = $fms->{zone}->{$zone};

		# Check peer information
		my $address = $c->tx->remote_address;
		my $port    = $c->tx->remote_port;
		
		$fl->DEB("Received /zone/$zone/$command/$value request from $address\:$port");

		if( !zone_available($zone) ) {
			$fl->ERR("Zone $zone does not match to a valid player mac in LMS");
			return $c->reply->not_found
		}

		# Define playerstates here because we have to modify the state below to 
		# sync the Loxone WebGUI 
		$playerstates = Clone::clone(\%main::playerstates);
		# $playerstates = \%main::playerstates; 

		switch ($command) {
			case 'play'  { 
				if ($value) {
					$lmscommand = "playlist play $value";
				} else {
					$lmscommand = "play";
				}
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
		&send("$player $lmscommand");
	
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

		if( !zone_available($zone) ) {
			$fl->ERR("Zone $zone does not match to a valid player mac in LMS");
			return $c->reply->not_found
		}

		# Read Player States and create output
		my $state = &create_state($zone);
		
		# Render in UTF8
		utf8::decode($state);
		utf8::decode($state);
		$c->res->headers->header('Content-Type' => 'application/json');
		$c->render(text => $state);

	};

	# Answer with global favorites
	get '/favorites/0' => sub {

		my $c = shift;
		#my $zone = $c->stash('zone');

		# Check peer information
		my $address = $c->tx->remote_address;
		my $port    = $c->tx->remote_port;
		
		$fl->DEB("Received /favorites/0 from $address\:$port");

		# Read global favorites from LMS
		my $lmsfavs = &create_fav();
		
		# Render in UTF8
		utf8::decode($lmsfavs);
		utf8::decode($lmsfavs);
		$c->res->headers->header('Content-Type' => 'application/json');
		$c->render(text => $lmsfavs);

	};

	# Answer with room Favorites
	get '/zone/:zone/favorites/0' => sub {

		my $c = shift;
		my $zone = $c->stash('zone');

		# Check peer information
		my $address = $c->tx->remote_address;
		my $port    = $c->tx->remote_port;
		
		$fl->DEB("Received /zone/$zone/favorites/0 from $address\:$port");

		if( !zone_available($zone) ) {
			$fl->ERR("Zone $zone does not match to a valid player mac in LMS");
			return $c->reply->not_found
		}

		# Read global favorites from LMS
		my $lmsfavs = &create_fav($zone);
		
		# Render in UTF8
		utf8::decode($lmsfavs);
		utf8::decode($lmsfavs);
		$c->res->headers->header('Content-Type' => 'application/json');
		$c->render(text => $lmsfavs);

	};

	# Receive new global favorite
	post '/favorites/:position' => sub {

		my $c = shift;
		#my $zone = $c->stash('zone');
		my $position = $c->stash('position');
		my $jsonrec = $c->req->body;

		# Check peer information
		my $address = $c->tx->remote_address;
		my $port    = $c->tx->remote_port;
		
		$fl->DEB("Received PUT /favorites/$position from $address\:$port");

		#if( !zone_available($zone) ) {
		#	$fl->ERR("Zone $zone does not match to a valid player mac in LMS");
		#	return $c->reply->not_found
		#}

		#$fl->DEB("Received JSON: $jsonrec");

		# Create json
		my $json;
		eval {
			$json = JSON::PP::decode_json( $jsonrec );
			1;
		} or do {
			$fl->DEB("Received JSON: Results seems not be valid json string");
			return;
		};

		$fl->DEB("Received JSON:\n" . Data::Dumper::Dumper($json)); 

		# Create new fav
		for my $item( @{$json} ){
			my $title = $item->{'title'};
			$title =~ s/\s/%20/g;

			# Send to LMS tcp queue
			$lmscommand = "favorites add url:$item->{'id'} title:$title";
			&send("$lmscommand");
		}

		# Read global favorites from LMS
		my $lmsfavs = &create_fav();
		
		# Render in UTF8
		utf8::decode($lmsfavs);
		utf8::decode($lmsfavs);
		$c->res->headers->header('Content-Type' => 'application/json');
		$c->render(text => $lmsfavs);

	};



	
	#
	# Start server
	#

	#app->start;
	app->start('daemon', '-l', "http://*:".$fms->{LocalWebPort});

}

#
# Create Player State
# Parameter is zone number
#
sub create_state {

	$fl->DEB("create_state called");

	my $zone = shift;
	my $player = $fms->{zone}->{$zone};

	if (! $playerstates ) {
		$playerstates = Clone::clone(\%main::playerstates);
		$fl->DEB("create_state: playerstates not yet defined. Will read them from main::playerstates");
	}

	$fl->DEB("create_state: Creating state for player " . $player);

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

	$fl->DEB("create_state: Mode is " . $playerstates->{$player}->{Mode});
	
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
			'id' => $playerstates->{$player}->{Path},
			'artist' => $playerstates->{$player}->{Artist},
			'duration' => int($playerstates->{$player}->{Duration}*1000),
			'image' => $playerstates->{$player}->{Cover}
		}
	);
	undef $playerstates;

	$fl->DEB("create_state: Response state:\n" . Data::Dumper::Dumper(%response)); 

	my $jsonresponse = JSON::PP::encode_json(\%response);

	return($jsonresponse);

}

#
# Create Favorites
# Parameter is zone
#
sub create_fav {
	
	$fl->DEB("create_fav called");

	my $zone = shift;
	my $item;

	#if (@_ != 2) {
	#	$fl->WARN("get_lmsdata: odd number of parameters");
	#	return;
	#}

	# Check fav subfolder for zone
	if ($zone) {
		$item = &get_fav_sub($zone);
		if ( !$item ) { # Create Subfolder if not exist
			$fl->DEB("create_fav: Could not find subfolder for room favs for Zone $zone");
			my $player = $fms->{zone}->{$zone};
			$fl->DEB("create_fav: Player MAC is $player");
			my $playername = $main::playerstates{$player}->{Name};
			$fl->DEB("create_fav: Player Name is $playername");
			my $title = "Zone $zone $playername";
			$fl->DEB("create_fav: Creating subfolder for roomfavs: $title");
			$title =~ s/\s/%20/g;
			my $lmscommand = "favorites addlevel title:$title";
			&send($lmscommand);
			sleep(10);
			$item = &get_fav_sub($zone);
			for (my $i = 1;$i <= 8;$i++) {
				my $lmscommand = "favorites add title:Fav%20$i url:file:/// item_id:$item.$i";
				&send($lmscommand);
			}
			#return();
		}
	} else {
		$item = "";
	}

	$fl->DEB("create_fav: Grabbing favorites");

	# Grab favorites from LMS
	my $lmsresp;
	if ( $item ) {
		$lmsresp = &get_lmsdata('{"id":1,"method":"slim.request","params":["XX:XX:XX:XX:XX:XX", ["favorites","items",0,10,"menu:favorites","useContextMenu:1","item_id:' . $item . '"]]}');
	} else {
		$lmsresp = &get_lmsdata('{"id":1,"method":"slim.request","params":["XX:XX:XX:XX:XX:XX", ["favorites","items",0,10,"menu:favorites","useContextMenu:1"]]}');
	}

	#$fl->DEB("create_fav: Response fav lms data:\n" . Data::Dumper::Dumper($lmsresp)); 
	
	# Create json
	my $json;
	eval {
		$json = JSON::PP::decode_json( $lmsresp );
		1;
	} or do {
		$fl->DEB("create_fav: Results seems not be valid json string");
		return;
	};

	my @items;
	my $i;
	for my $item( @{$json->{result}->{item_loop}} ){
		$fl->DEB("create_fav: Found item $item->{text}");
		# Skip menu buttons
		if ( !$item->{'presetParams'} ) {
			next;
		}
		# There are several ways icons are given
		my $icon;
		if ( $item->{'presetParams'}->{'icon'} =~ /^http/ ) {
			$icon = $item->{'presetParams'}->{'icon'};
		} else {
			$item->{'presetParams'}->{'icon'} =~ s/^\/+//g;
			$icon = "http://" . $main::squ_server . ":" . $main::squ_lmswebport . "/" . $item->{'presetParams'}->{'icon'}
		}
		# Filter empty FAVs
		my %itemdata;
		if ( $item->{'presetParams'}->{'favorites_title'} =~ m/^Fav \d$/ ) {
			%itemdata = (
				'id' => '',
				'title' => '',
				'image' => ''
			);
		} else {
			%itemdata = (
				'id' => $item->{'presetParams'}->{'favorites_url'},
				'title' => $item->{'presetParams'}->{'favorites_title'},
				'image' => $icon
			);
		}
		#$fl->DEB("create_fav: Created hash:\n" . Data::Dumper::Dumper(\%itemdata)); 

		# Only 8 favs are supported by Loxones UI
		$i++;
		if ( $i > 8 ) { last; };
		push (@items, \%itemdata);
	}
	
	#$fl->DEB("create_fav: Created hash:\n" . Data::Dumper::Dumper(\@items)); 

	my %response = (
		'total' => scalar @items,
		'items' => \@items
	);

	my $jsonresponse = JSON::PP::encode_json(\%response);

	return($jsonresponse);

}

#
# Get index_id for subfolder of room fav
# Parameter is zone
#
sub get_fav_sub {
	
	$fl->DEB("get_fav_sub called");

	my $zone = shift;
	my $id;

	$fl->DEB("get_fav_sub: Grabbing favorites");

	# Grab favorites from LMS
	my $lmsresp = &get_lmsdata('{"id":1,"method":"slim.request","params":["XX:XX:XX:XX:XX:XX", ["favorites","items",0,10,"menu:favorites","useContextMenu:1"]]}');

	#$fl->DEB("create_fav: Response fav lms data:\n" . Data::Dumper::Dumper($lmsresp)); 
	
	# Create json
	my $json;
	eval {
		$json = JSON::PP::decode_json( $lmsresp );
		1;
	} or do {
		$fl->DEB("get_fav_sub: Results seems not be valid json string");
		return;
	};

	my @items;
	for my $item( @{$json->{result}->{item_loop}} ){
		$fl->DEB("get_fav_sub: Found item $item->{text}");
		# This is a subfolder - check
		if ( $item->{addAction} && $item->{addAction} eq "go" ) {
			my ($txt,$subzone) = split ( / /, $item->{text} );
			if ( $subzone eq $zone ) { # Found correct subfolder
				$fl->DEB("get_fav_sub: Found subfolder for zone $zone: $item->{text}");
				my ($rnd,$itemid) = split ( /\./, $item->{actions}->{go}->{params}->{item_id} );
				$id = $itemid;
				last;
			}
		} else {
			next;
		}
	}
	
	return($id);

}

#
# Grab data from LMS in JSON format
# Parameter is request in JSON format
#
sub get_lmsdata {

	$fl->DEB("get_lmsdata called");

	use WWW::Curl::Easy;
	my ($request) = @_;
	
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
        	$fl->ERR("get_lmsdata: An error happened: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf);
		return;
	}
	$fl->DEB("get_lmsdata: Request successfull");

	return ( $response_body );

}

#
# Checks if the requested zone has an available mac defined
# Parameter is zone number
#
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

#
# Send to LMS tcp queue
# The queue is managed by the main thread
# Parameter is lms command
#
sub send
{

	my ($lmscommand) = @_;

	# During lock, other threads will wait for release 
	$fl->DEB("Sending command to LMS: $lmscommand");
	threads::shared::lock(@main::tcpout_queue);
	push @main::tcpout_queue, "$lmscommand\n";
	# Lock is released automatically after leaving the scope of the block
	return();

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
