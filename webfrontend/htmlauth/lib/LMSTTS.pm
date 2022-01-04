use forks;
use forks::shared;
# use threads qw(stringify);
# use threads::shared;


use LoxBerry::Log;
use warnings;
use strict;
use Time::HiRes;
use WWW::Curl::Easy;
use WWW::Curl::Multi;
BEGIN { $ENV{PERL_JSON_BACKEND} = 'JSON::PP' } # Parsing JSON does not work with the default JSON parser in threads
use JSON;

# Debugging
require Data::Dumper;
				

	
# use Digest::MD5;

package LMSTTS;

# $guest_answer = LMSTTS::tts($tcpout_sock, \@guest_params, \%playerstates);

our $ttsqueue_tid : shared;
our $ttsqueue_thr;
#our @ttsqueue : shared;
our @ttsqueue : shared;
# Init a Curl::Multi object for parallel URL processing
my $curlhandlecount = 0;				# Number of known curl handles
my $curlm_active = 0;					# Number of active curl handles
our %curlids; 							# Store for Curl handles
our %local_queue_data;
my $playerstates;
	
my $cfg;

my $max_threads_generate_mp3 = 1;
my $tts_plugin_hostname;
my $tts_queue_cycle_ms;
my $tts_play_timeout_sec : shared;

my $tl; # TTS Log object
my $pl; # PLAY Log object
our $logdbkey : shared; # TTS Log ID to append

###############################################################################
# sub tts is the main function to queue up new texts, and to send control 
# messages to the queue. The queue itself is it's own thread, but started from 
# the tts sub, if not already running. The tts sub must return immediately 
# after option processing and queuing to not interfere the lms2udp daemon.

sub tts {

	my $tcpout_sock = shift;
	my $params = shift;
	my $playerstates = shift;
	
	# Create TTS queue thread
	if(!$ttsqueue_tid) {
		$ttsqueue_thr = threads->create('tts_queue', $playerstates);
		$main::log->OK("LMSTTS: Created TTS thread with thread id " . $ttsqueue_thr->tid());
		$main::threads{$ttsqueue_thr->tid()} = $ttsqueue_thr->tid();
	} else {
		$main::log->DEB("LMSTTS: Queue already running with TID $ttsqueue_tid");
	}
	if(!$ttsqueue_thr) {
		$main::log->ERR("LMSTTS: Could not create LMSTTS queue thread");
	}
	
	my $answer = "";
	
	#my $player = $params[2];
	#my $playername = $$playerstates{$player}->{Name};
	
	#$answer .= "TTS-Player: " . $player . " (" . $playername . ")\n";
	
	# Parse key/value pairs
	require Getopt::Long;
	my %opt = ();
	my $ret = Getopt::Long::GetOptionsFromString($params, \%opt, 
		'player=s@',
		'text=s', 
		'force',
	);
	
	if (!$opt{player}) {
		$main::log->ERR("LMSTTS: No players defined in calling parameters - discarding call.");
		return;
	}
	
	my $player = $opt{player};
	@$player = split(/,/,join(',',@$player));
	
	my @invalid_players;
	# We allow to use player names instead of MAC addresses
	# Therefore we need to replace names by MACs
	foreach my $key (keys @{$opt{player}}) {
		$main::log->DEB("LMSTTS: Player $opt{player}[$key]");
		if(!defined $$playerstates{$opt{player}[$key]}) {
			$main::log->DEB("LMSTTS: Player option $opt{player}[$key] seems to be a name not mac address - seaching"); 
			my $mac = main::search_in_playerstate("Name", $opt{player}[$key]);
			if ($mac) {
				$main::log->DEB("LMSTTS: Found player $mac for $opt{player}[$key]");
				$opt{player}[$key] = $mac;
			} else {
				$main::log->WARN("LMSTTS: Player $opt{player}[$key] not found - will be removed from call");
				push @invalid_players, $key;
				
			}
		}
	}
	foreach my $key(@invalid_players) {
		delete($opt{player}[$key]);
	}
	
	if( ! @{$opt{player}} ) {
	
		$answer = "LMSTTS: No valid players defined - discarding call.";
		$main::log->ERR($answer);
		return $answer;

	} else {
		$opt{qid} = Time::HiRes::time();
		{ 
			lock(@ttsqueue);
			push @ttsqueue, \%opt;
		}
		$answer = "LMSTTS: Queued $opt{player}[0]";
	}
	
	$main::log->OK($answer);
	return $answer;

}


###############################################################################
# TTS Queue
# The tts_queue runs as own thread and quits after a 5 minute idle time
# It needs to manage the queue entries, generating the tts mp3s and save and
# restore the player states. 
# It creates threads for tts creation and is watching the playerstates
###############################################################################

sub tts_queue
{
	print "THREAD TTS_QUEUE ==================================== START ==\n";
	require Clone;
	require Array::Utils;
	
	# Init Logfile
	$tl = LoxBerry::Log->new (
		name => 'TTS',
		filename => $main::lbplogdir . '/lmstts.log',
		loglevel => 7,
		stderr => 0,
		addtime => 1,
		append => 1,
	);
	$tl->LOGSTART("TTS queue started");
	$logdbkey = $tl->dbkey();
	
	$playerstates = shift;
		
	$cfg=$main::cfg;

	$max_threads_generate_mp3 = $cfg->param("LMSTTS.max_threads_generate_mp3");
	if (! $max_threads_generate_mp3) { $max_threads_generate_mp3=1 };
	my $queue_shutdown_on_idle_sec = $cfg->param("LMSTTS.queue_shutdown_on_idle_sec");
	if (! $queue_shutdown_on_idle_sec) { $queue_shutdown_on_idle_sec = 60; };
	$tts_plugin_hostname = $cfg->param("LMSTTS.tts_plugin_hostname");
	if (! $tts_plugin_hostname) { $tts_plugin_hostname = "localhost:80"; };
	$tts_queue_cycle_ms = $cfg->param("LMSTTS.tts_queue_cycle_ms");
	if (! $tts_queue_cycle_ms) { $tts_queue_cycle_ms = 20; };
	$tts_play_timeout_sec = $cfg->param("LMSTTS.tts_play_timeout_sec");
	if (! $tts_play_timeout_sec) { $tts_play_timeout_sec = 120; };
	
	$tl->INF("Thread parameters:");
	$tl->INF("max_threads_generate_mp3   : " . $max_threads_generate_mp3);
	$tl->INF("queue_shutdown_on_idle_sec : " . $queue_shutdown_on_idle_sec);
	$tl->INF("tts_plugin_hostname        : " . $tts_plugin_hostname);
	$tl->INF("tts_queue_cycle_ms         : " . $tts_queue_cycle_ms);
	$tl->INF("tts_play_timeout_sec       : " . $tts_play_timeout_sec);
	
	
	
	
	our $curlm = WWW::Curl::Multi->new; 		# Curl parallel processing object
	# $curlm->setopt(WWW::Curl::Easy::CURLMOPT_MAXCONNECTS, $max_threads_generate_mp3);
	
	
	
	
	my $lastrequest_epoch = time;
	my %saved_states;
		
	$ttsqueue_tid = threads->tid();
	$tl->OK("TTS queue ($ttsqueue_tid): Created with TID $ttsqueue_tid");
	
	
	while( ($lastrequest_epoch+$queue_shutdown_on_idle_sec) > time or @ttsqueue) {
	
		# print "TTS queue ($ttsqueue_tid): " . scalar @ttsqueue . " elements queued (active for " . (time-$lastrequest_epoch) . "s)\n";
		
		## Call the generation of MP3's
		generate_tts_mp3();
		
		## Manage playing
		init_play();
		
		## Handle Callback
		handle_callback();

		## Check if a force 
		
		# Checks is resuming has finished
		check_resumed();
		
		## Unqueue finished or delayed elements
		unqueue();
		
		
		# ### DEBUG
		# foreach(@ttsqueue) {
			# $tl->DEB("Queue element: $_->{qid}");
			# my @tts_players = @{ $_->{player} };
		
			# foreach my $player ( @tts_players ) {
				# $tl->DEB("    Player: $player");
			# }
		# }
		# sleep(1);
		# ### /DEBUG
		
		
		
		
		
		
		
		$lastrequest_epoch = time if ($curlhandlecount > 0);
		Time::HiRes::usleep ($tts_queue_cycle_ms*1000);
		
	
	}

	$tl->OK("TTS queue ($ttsqueue_tid): Closing due to inactivity");
	$ttsqueue_tid = undef;
	$tl->LOGEND();
	return;
	
}

# Requests the queued texts as MP3's 
# Uses @ttsqueue and $curlm as global variable
sub generate_tts_mp3
{

	# Check if curl handles have finished
	if($curlhandlecount > 0 and $curlhandlecount != $curlm_active) {
		# Check running sessions
		while (my ($qid,$return_value) = $LMSTTS::curlm->info_read) {
			$tl->INF("CURL processed $qid (Return value $return_value)");
			if ($qid) {
				$curlhandlecount--;
				my $curl_handle = $curlids{$qid};
				$local_queue_data{$qid}{resp_code} = $curl_handle->getinfo(WWW::Curl::Easy::CURLINFO_RESPONSE_CODE);
				delete $curlids{$qid};
				$tl->INF("generate_tts_mp3 curl Response code: $local_queue_data{$qid}{resp_code}");
				# print $local_queue_data{$qid}{curl_response} . "\n";
				
				# Check to have a success response
				if( ! $local_queue_data{$qid}{resp_code} or $local_queue_data{$qid}{resp_code} >= 400 ) {
					$tl->ERR("Generation of $qid failed: HTTP error $local_queue_data{$qid}{resp_code}");
					$local_queue_data{$qid}{mp3_state} = "failed";
					next;
				}
				
				# Parse json and check if no valid json is given
				print "RESPONSE: " . $local_queue_data{$qid}{curl_response} . "\n";
				my $json;
				my $jsonobj;
				eval {
					#$jsonobj = new JSON;
					#$jsonobj->allow_nonref(1);
					$json = JSON->new->allow_nonref(1)->utf8->decode( $local_queue_data{$qid}{curl_response} );
				};
				if ($@) {
					my $error = $@;
					$tl->ERR("QID $qid: Not a valid JSON file returned");
					$tl->INF($error);
					$tl->INF($local_queue_data{$qid}{curl_response});
					$local_queue_data{$qid}{mp3_state} = "failed";
					next;
				}

				# Read and check content of json 
				$local_queue_data{$qid}{mp3_url} = $json->{'full-httpinterface'};
				$local_queue_data{$qid}{mp3_md5} = $json->{'mp3-filename-MD5'};
				$local_queue_data{$qid}{mp3_duration_ms} = $json->{'duration-ms'};
				
				if(!$local_queue_data{$qid}{mp3_md5} or $local_queue_data{$qid}{mp3_md5} eq "") {
					$tl->ERR("QID $qid: No MD5 hash returned - request seems to have failed");
					$local_queue_data{$qid}{mp3_state} = "failed";
					next;
				}
				
				# We are save
				$local_queue_data{$qid}{mp3_state} = "ready";
				$tl->INF("MP3-URL: $json->{'full-httpinterface'}");
				
				
				
			}
		}
	}

	# Unqueue failed entries
	foreach my $qid (keys %local_queue_data) {
		next if(! defined $local_queue_data{$qid}{mp3_state} or $local_queue_data{$qid}{mp3_state} ne "failed");
		$tl->WARN("Unqueue QID $qid because of failed MP3 conversion");
		eval {
			threads::shared::lock(@ttsqueue);
			@ttsqueue = grep { defined $_->{qid} and $_->{qid} ne $qid } @ttsqueue;
		};
		if($@) {
			$tl->ERR("unqueue Exception caught: $@");
		}
		delete $local_queue_data{$qid};
	}

	## Generate TTS mp3's
	# Only queue if max_count is not reached
	if( $curlhandlecount < $max_threads_generate_mp3 ) {
		foreach (@ttsqueue) {
			my $qid = $_->{qid};
			next if($local_queue_data{$qid}{mp3_state});
			next if($curlhandlecount > $max_threads_generate_mp3);
			$local_queue_data{$qid}{mp3_state} = "processing";
			$tl->INF("   Element $_->{text} State " . $local_queue_data{$qid}{mp3_state});
			
			my $ttsif_url = "";
			$ttsif_url .= "http://" . $tts_plugin_hostname . "/plugins/text2speech/index.php";
			$ttsif_url .= "?json=1";
			$ttsif_url .= "&text=" . URI::Escape::uri_escape($_->{text});
			
			#my $curlid = Digest::MD5::md5($qelem->{text}, Time::HiRes::time());
			my $curl = WWW::Curl::Easy->new;
			$curlids{$qid} = $curl;
			$curl->setopt( WWW::Curl::Easy::CURLOPT_PRIVATE, "$qid" );
			$curl->setopt( WWW::Curl::Easy::CURLOPT_URL, $ttsif_url );
			#$curl->setopt( WWW::Curl::Easy::CURLOPT_ERRORBUFFER, \$local_queue_data{$qid}{curl_errors});
			$curl->setopt( WWW::Curl::Easy::CURLOPT_WRITEDATA,\$local_queue_data{$qid}{curl_response});
			$curl->setopt( WWW::Curl::Easy::CURLOPT_TIMEOUT, 30);
			my $curl_addhandle_resp = $LMSTTS::curlm->add_handle($curl);
			# print "curl add_handle response: $curl_addhandle_resp\n";
			$tl->INF("Queuing curl TTS interface with qid $qid. URL:");
			$tl->DEB("$ttsif_url");
			$curlhandlecount++;
			
		}
	}
	# Process parallel curl requests
	
	if($curlhandlecount > 0) {
		$LMSTTS::lastrequest_epoch = time;
		$curlm_active = $LMSTTS::curlm->perform;
		$tl->INF("Performing curl requests ($curlhandlecount handles, $curlm_active active)");
	}
}		


##########################################################
# init_play 
# Manages saving, starting and restoring the states
##########################################################

sub init_play
{
	# We collect players that are currently in use
	my %workingplayers;
	
	# Walk through the queue
	foreach(@ttsqueue) {
		my $qid = $_->{qid};
		
		## Read the players that this event should manage
		my $players_in_use = 0;
		my @tts_players = @{ $_->{player} };
			
		foreach my $player (@tts_players) {
			if($workingplayers{$player}) {
				$tl->INF("Player $player is currently in use - skipping this round");
				$players_in_use = 1;
				last;
			}
		}
		next if($players_in_use);
				
		# Check for ready mp3's - mp3 is ready and currently no play_state
		if( $local_queue_data{$qid}{mp3_state} eq "ready" and !$local_queue_data{$qid}{play_state} ) {
			$tl->INF("Element $qid is ready for playing");
			# This queue element is ready to play
			
			%workingplayers = map { $_ => 1 } @tts_players;
			
			## Read all players that currently playing TTS
			# Getting all currently playing, involved players from the full queue
			my @playing_players;
			foreach my $qelem (@ttsqueue) {
				# Skip myself
				next if ($qelem->{qid} eq $qid);
				# Skip if the queue element is not in process
				next if (!$local_queue_data{$qelem->{qid}}{play_state});
				# This queue element is playing - add it's players to the array
				push @playing_players, @{ $qelem->{player} };
			}
			
			# Now check if one of the requested players currently is playing for another queue element
			my @player_matches = Array::Utils::intersect(\@tts_players, \@playing_players);
			# This returns all matching elements - if it has values, the current element has to wait
			if(@player_matches) {
				$tl->DEB("Element $qid has to wait, because other queue elements currently use it's players");
				next;
			}
			# Request song play time before further processing
			foreach my $player (@tts_players) {
				$playerstates->{$player}->{time} = 0;
				tcpoutqueue("$player time ?");
			}
			
			# We requested the time - check if we got it
			$tl->DEB("Waiting for the song time...");
			foreach (@tts_players) {
				if( ($playerstates->{$_}->{Mode} eq "0" or $playerstates->{$_}->{Mode} eq "1") and !$playerstates->{$_}->{time} ) {
					Time::HiRes::sleep(0.02);
					redo;
				}
			}
			
			$tl->OK("All used players are ready to rumble");
			$local_queue_data{$qid}{play_state} = "playing";
			
			# Wait for the song time
			Time::HiRes::sleep(0.08);
			
			my @savedstates;
			foreach my $player (@tts_players) {
				
				$tl->DEB( "Playerstate of " . $playerstates->{$player}->{Name} . ": " . $playerstates->{$player}->{Mode} . " (-1 Stopped, 0 Pause, 1 Playing)");
				#my $state = Clone::clone(\%{$playerstates->{$player}});
				#$local_queue_data{$qid}{backup_playerstate}{$player} = \$state;
				$local_queue_data{$qid}{backup_playerstate}{$player} = { %{$playerstates->{$player}} };
				$tl->DEB( Data::Dumper::Dumper($local_queue_data{$qid}{backup_playerstate}{$player}) );
				
			}
			my $localdata = threads::shared::shared_clone($local_queue_data{$qid});
			$local_queue_data{$qid}{play_thread} = threads->create('tts_play', $playerstates, $_, $localdata);
			
			# # List current players
			# foreach my $player (keys %$playerstates) {
				# print "Player: " . $playerstates->{$player}->{Name} . "\n";
			# }
		
		}
		
		
		
	
	}
}

#######################################################################
# handle_callback
# Collect all players that have finished and restore state 
#######################################################################

sub handle_callback
{
	$tl->DEB("--> handle_callback") if (@ttsqueue);
	
	foreach(@ttsqueue) {
		my $qid = $_->{qid};
		
		# ## Do not do a callback after at least 2 seconds
		# if (Time::HiRes::time < $qid+2) {
			# next;
		# }
		
		
		
		## Handle callback
		if( defined $local_queue_data{$qid}{play_thread} and $local_queue_data{$qid}{play_thread}->is_joinable() ) {
			$tl->OK( "Joining player thread TID" . $local_queue_data{$qid}{play_thread}->tid());
			$local_queue_data{$qid}{play_state} = $local_queue_data{$qid}{play_thread}->join();
			
			# Restore the sync state of the involved players
			my @tts_players = @{ $_->{player} };
			foreach my $player (@tts_players) {
				# Read the saved state
				my $state = $local_queue_data{$qid}{backup_playerstate}{$player};
								
				$tl->DEB( "Saved player state:" );
				$tl->DEB( Data::Dumper::Dumper($state) );
				$tl->DEB( "Restore: Name $state->{Name} ($player) Mode $state->{Mode} ");
				$tl->DEB( "Sync $state->{sync}") if ($state->{sync});
				
				my @synced_backup = split (/,/, $state->{sync}) if ($state->{sync});
				
				if(@synced_backup) {
					
					### The player was member of a sync group ###
					
					# Get all players, that was not in the tts group
					my @non_tts_members = remove_from_array(\@synced_backup, \@tts_players);
					
					if(! @non_tts_members) {
						# ALL tts members were in the same syncgroup before
						$tl->DEB( "All tts members were in the same group" );
						# Do NOTHING
					} else {
						# The backuped sync group had more members ->
						# Sync the current player to the first remaining player
						## SYNC parameter: Note that in both cases the first <playerid> is the player which is already a member of a sync group. When adding a player to a sync group, the second specified player will be added to the group which includes the first player, if necessary first removing the second player from its existing sync-group. 
						$tl->DEB( "Synching $playerstates->{$player}->{Name} ($player) to $playerstates->{$non_tts_members[0]}->{Name} ($non_tts_members[0])" );
						tcpoutqueue("$non_tts_members[0] sync $player");
					}
				} else {
					
					$tl->DEB( "$player was not synct to a group restore playlist" );
					tcpoutqueue("$tts_players[0] playlist preview cmd:stop");
				}
				
				
				Time::HiRes::sleep(0.03);
				
				# Restore volume
				$tl->INF ("Restoring volume to $state->{volume}");
				tcpoutqueue("$player mixer volume " . $state->{volume});
											
				# Restore playing mode, if it was playing, and was not turned off during TTS
				if ($state->{Power} == 0) {
					$tl->INF ("Turning off player, as it was turned off before");
					tcpoutqueue("$player power 0");
				} elsif ($state->{Mode} == 1 and $playerstates->{$player}->{Power} == 1 ) {
					$tl->INF ("Resume playing");
					tcpoutqueue("$player play 1");
				}
				
				# Restore playtime
				if ($state->{Stream} == 0 and $state->{time}) {
					$tl->INF ("Restoring playtime - jump to $state->{time}");
					tcpoutqueue("$player time " . $state->{time});
				}
				
				# Restore shuffle
				if ($state->{Shuffle}) {
					$tl->INF ("Restoring shuffle - setting to $state->{Shuffle}");
					tcpoutqueue("$player playlist shuffle " . $state->{Shuffle});
				}
				
				# Query current mode
				tcpoutqueue("$player power ?");
				tcpoutqueue("$player title ?");
				tcpoutqueue("$player playlist shuffle ?");
				tcpoutqueue("$player playlist repeat ?");
				tcpoutqueue("$player mixer muting ?");
			}
			
			#tcpoutqueue("$player title ?");
			#tcpoutqueue("syncgroups ?");
			
			# Set the queue state to unqueue
			$tl->INF( "Setting queue element to resumed" );
			$local_queue_data{$qid}{resuming} = 1;
		
		}
	}


}

##########################################################
# check_resumed
# As resuming takes some time, we have to wait until
# LMS has fully resumed the old playlist
##########################################################
sub check_resumed
{
	foreach(@ttsqueue) {
		my $ready_to_unqueue = 1;
		my $qid = $_->{qid};
		next if( !$local_queue_data{$qid}{resuming} );
		
		my @tts_players = @{ $_->{player} };
		foreach my $player (@tts_players) {
				
			# Read the saved state
			my $state = $local_queue_data{$qid}{backup_playerstate}{$player};
			#$tl->DEB( "check_resumed: Saved player state:" );
			#$tl->DEB( "check_resumed: " . Data::Dumper::Dumper($state) );
			
			# Check play state
			if (defined $state->{Mode}) {
				if( ($state->{Mode} == 1 or $state->{Mode} == 0) and $playerstates->{$player}->{Mode} < 0 ) {
					$tl->DEB("Player $state->{Name} ($player): Mode not yet restored (<0): Saved {$state->{Mode}}, Current {$playerstates->{$player}->{Mode}}");  
					$ready_to_unqueue = 0;
					last;
				}
				if( defined $state->{Mode} and $state->{Mode} == -1 and $playerstates->{$player}->{Mode} != -1 ) {
					$tl->DEB("Player $state->{Name} ($player): Mode not yet restored (!-1): Saved {$state->{Mode}}, Current {$playerstates->{$player}->{Mode}}");  
					$ready_to_unqueue = 0;
					last;
				}
			}

			if(defined $state->{Shuffle}) {
				if( defined $state->{Shuffle} and $state->{Shuffle} != $playerstates->{$player}->{Shuffle} ) {
					$tl->DEB("Player $state->{Name} ($player): Shuffle not yet restored: Saved {$state->{Shuffle}}, Current {$playerstates->{$player}->{Shuffle}}");  
					$ready_to_unqueue = 0;
					last;
				}
			}
		}
		
		
		if($ready_to_unqueue == 1) {
			$tl->OK("Player check ok - Setting $qid to unqueue");
			$local_queue_data{$qid}{unqueue} = 1;
		}
		
		# Unqueue after $tts_play_timeout_sec (120) seconds, if player did not resume
		if( Time::HiRes::time() > ($qid+$tts_play_timeout_sec) ) {
			$tl->ERR("Player did not resume - GIVING UP and unqueue (timeout $tts_play_timeout_sec secs)");
			$local_queue_data{$qid}{unqueue} = 1;
		}
		
			

	}

}





##########################################################
# tts_play
# The playing thread
##########################################################

sub tts_play
{

	my $playerstates = shift;
	my $queue_element = shift;
	my $local_data = shift;
	my $result = "failed";
	
	$pl = LoxBerry::Log->new (
		dbkey => $logdbkey
	);
	
	my $tid = threads->tid();
	$pl->OK ("PLAY TID$tid: THREAD STARTED with QID " . $queue_element->{qid});
	$pl->INF ("PLAY TID$tid: MP3_URL is " . $local_data->{mp3_url} . ", length is " . printf("%.1f", $local_data->{mp3_duration_ms} / 1000) . " sec");
	
	my @tts_players = @{ $queue_element->{player} };
	
	# Unsync and pause
	foreach( @tts_players ) {
		$pl->DEB( "PLAY TID$tid: Unsyncing and pausing $_" );
		tcpoutqueue("$_ sync -");
		tcpoutqueue("$_ pause 1 1");	
	}
	
	# Sync
	if (scalar @tts_players > 1) {
		my $playercount = scalar @tts_players;
		$pl->INF( "PLAY TID$tid: TTS uses $playercount zones - syncing..." );
		for (my $i = 1; $i <= $playercount-1; $i++) {
			$pl->DEB ( "PLAY TID$tid:   Sync $tts_players[$i] --> $tts_players[0]" );
			tcpoutqueue("$tts_players[0] sync $tts_players[$i]");
		}
	}
	
	# Disable shuffle if enabled
	if($playerstates->{$tts_players[0]}->{Shuffle}) {
		$pl->INF("PLAY TID$tid: Shuffle is in mode " . $playerstates->{$tts_players[0]}->{Shuffle} . " and now disabled");
		tcpoutqueue("$tts_players[0] playlist shuffle 0");
	}
	
	# Set volume specific to options or config
	foreach( @tts_players ) {
		my $volset = calculate_volume(
			$playerstates->{$_}->{volume}, 
			$queue_element->{lmsvol}, 
			$queue_element->{minvol}, 
			$queue_element->{maxvol}
		);
		if ($volset) {
			$pl->INF("PLAY TID$tid: Setting volume to calculated volume $volset" );
			tcpoutqueue("$_ mixer volume $volset");
		} else {
			$pl->WARN("PLAY TID$tid: Could not calculate a volume to set - skipping volume");
		}
	}
	
	# Backup/Play
	$pl->OK("PLAY TID$tid: Sending MP3 to backup playlist and enqueue TTS-MP3" ); 
	tcpoutqueue("$tts_players[0] playlist preview url:" . URI::Escape::uri_escape($local_data->{mp3_url}) . " title:" . URI::Escape::uri_escape($queue_element->{text}));

	# Wait
	my $starttime = time;
	my $mp3_duration = $local_data->{mp3_duration_ms}/1000;
	if (!$mp3_duration or $mp3_duration == 0) {
		$mp3_duration = $tts_play_timeout_sec;
		$pl->WARN("PLAY TID$tid: Could not determine TTS length from MP3. Setting to tts_play_timeout_sec"); 
	}
	
	my $maxendtime = time+$mp3_duration+5;
	
	# Wait until playing
	$pl->INF("PLAY TID$tid: Waiting for LMS to start to play");
	Time::HiRes::sleep(0.5);
	while( $playerstates->{$tts_players[0]}->{Mode} != 1 and time < $maxendtime) {
		$pl->DEB( "PLAY TID$tid: Waiting for LMS to start playing TTS" );
		Time::HiRes::sleep(0.2);
	}
	
	if (time > $maxendtime) {
		$pl->ERR("PLAY TID$tid: Player did not start to play - Quitting waiting loop");
		$result = "timeout";
	} else {
		$pl->INF("PLAY TID$tid: Player started - Waiting to finish");
		while (time < $maxendtime) {
			Time::HiRes::sleep(0.15);
			$pl->DEB("PLAY TID$tid:   Playerstate is in mode " . $playerstates->{$tts_players[0]}->{Mode} . " (1=playing) - Waiting...");
			if ($playerstates->{$tts_players[0]}->{Mode} < 1) {
				last;
			}
		}
		if (time >= $maxendtime) {
			$pl->ERR("PLAY TID$tid: Quitting because of timeout.");
			$pl->DEB("PLAY TID$tid: Playerstates of first player:");
			$pl->DEB(Data::Dumper::Dumper($playerstates->{$tts_players[0]}));
			$result = "timeout";
		} else {
			$pl->OK("PLAY TID$tid: Finished successfully");
			$result = "success";
		}
	}
	
	# Unsync
	if (scalar @tts_players > 1) {
		$pl->INF("PLAY TID$tid: Unsyncing all players");
		foreach( @tts_players ) {
			$pl->DEB( "PLAY TID$tid:   Unsyncing $_" );
			tcpoutqueue("$_ sync -");
		}
	}
	
	$pl->OK("PLAY TID$tid: Player thread closes");
	return $result;

}

##########################################################
# unqueue
# Manages saving, starting and restoring the states
##########################################################

sub unqueue 
{

	foreach my $qid (keys %local_queue_data) {
		next if(! defined $local_queue_data{$qid}{unqueue});
		$tl->INF ("Unqueue QID $qid because it has finished");
		eval {
			threads::shared::lock(@ttsqueue);
			my ($index) = grep { $ttsqueue[$_]->{qid} eq $qid } 0..$#ttsqueue;
			$tl->DEB("Found array index of $qid is $index");
			splice (@ttsqueue, $index, 1);
			#@ttsqueue = grep { defined $_->{qid} and $_->{qid} ne $qid } @ttsqueue;
		};
		if($@) {
			$tl->ERR ("Unqueue Exception caught: $@");
		}
		delete $local_queue_data{$qid};
	}
}





##########################################################
# tcpoutqueue
# Puts messages to the LMS sending queue
##########################################################

sub tcpoutqueue
{
	my ($message) = @_;
	$tl->DEB ("TCPOUT Queue: $message");
	{
		threads::shared::lock(@main::tcpout_queue);
		push @main::tcpout_queue, $message;
	}
	# my @msg = split(/ /, $message);
}


##########################################################
# calculate_volume
# Calculates the relative volume from options and default,
# that should be added to the current volume. The return
# may also be negative
# Parameters are current volume, (lmsvol, minvol and maxvol) from 
# the# getopt parameter. The default from the config are
# read by the function itself
##########################################################
sub calculate_volume
{
	my ($curr_vol, $opt_lmsvol, $opt_minvol, $opt_maxvol) = @_;
	my $result;
	# print "Shared main::tts_lmsvol: " . $main::tts_lmsvol . "\n";
	my $vol = defined $opt_lmsvol ? $opt_lmsvol : $main::tts_lmsvol;
	my $min = defined $opt_minvol ? $opt_minvol : $main::tts_minvol;
	my $max = defined $opt_maxvol ? $opt_maxvol : $main::tts_maxvol;
	
	$tl->DEB("calculate_vol: vol $vol | min $min | max $max");
	
	
	# Parse the volumes
	if(!$vol) {
		# No default: Use current volume
		$result = $curr_vol;
		$tl->DEB("calculate_vol: No volume - use curr_vol $result");

	} 
	elsif(substr($vol, 0, 1) eq "+" or substr($vol, 0, 1) eq "-" ) {
		# Relative volume
		$result = eval ( "$curr_vol" + substr($vol, 1) );
		$tl->DEB("calculate_vol: Relative volume - use $result");
	}
	else {
		$result = $vol;
		$tl->DEB("calculate_vol: Absolute volume - use $result");
	}
	
	# Min/Max check
	if(defined $min and $min>$result) {
		$result = $min;
		$tl->DEB("calculate_vol: Min-Check - use $result");
	}
	if(defined $max and $max<$result) {
		$result = $max;
		$tl->DEB("calculate_vol: Max-Check - use $result");
	}
		
	# print "Resulting volume: $result\n";
	$tl->DEB("calculate_vol: Finally use $result");
	return $result;

}

########################################################
# Remove the elements of the second array from the first
# Parameter 1: arrayref All elements
# Parameter 2: arrayref Elements to remove
# Return Resulting Array
sub remove_from_array
{
	my ($full, $away) = @_;
	return grep { my $f = $_; ! grep $_ eq $f, @$away } @$full;
}

##########################
# Thread

sub testthread2 
{
	my ($player) = @_;
	print STDERR "THREAD STARTED =========================================";
	print STDERR "Player $player is " . $main::playerstates{$player}->{Name} . "\n";


}



#####################################################
# Finally 1; ########################################
#####################################################
1;