# use forks;
# use forks::shared;
use warnings;
use strict;
use Time::HiRes;
use WWW::Curl::Easy;
use WWW::Curl::Multi;
BEGIN { $ENV{PERL_JSON_BACKEND} = 'JSON::PP' } # Parsing JSON does not work with the default JSON parser in threads
use JSON;
	
# use Digest::MD5;

package LMSTTS;

# $guest_answer = LMSTTS::tts($tcpout_sock, \@guest_params, \%playerstates);

our $ttsqueue_tid : shared = undef;
our $ttsqueue_thr;
#our @ttsqueue : shared;
our @ttsqueue : shared;
# Init a Curl::Multi object for parallel URL processing
my $curlhandlecount = 0;				# Number of known curl handles
my $curlm_active = 0;					# Number of active curl handles
our %curlids; 							# Store for Curl handles
our %local_queue_data;
	
my $cfg;

my $max_threads_generate_mp3 = 1;
my $tts_plugin_hostname;

###############################################################################
# sub tts is the main function to queue up new texts, and to send control 
# messages to the queue. The queue itself is it's own thread, but started from 
# the tts sub, if not already running. The tts sub must return immediately 
# after option processing and queuing to not interfere the lms2udp daemon.

sub tts {

	
	# Create TTS queue thread
	if(!$ttsqueue_tid) {
		$ttsqueue_thr = threads->create('tts_queue');
	}
	
	# my ($tcpout_sock, $params) = @_; 
	
	my $tcpout_sock = shift;
	my $params = shift;
	my $playerstates = shift;
	
	print STDERR "THREAD TTS ==================================== START ==\n";
	
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
		print "TTS: No player defined";
		return;
	}
	
	my $player = $opt{player};
	@$player = split(/,/,join(',',@$player));
	
	# We allow to use player names instead of MAC addresses
	# Therefore we need to replace names by MACs
	foreach my $key (keys @{$opt{player}}) {
		print "LMSTTS: Player $opt{player}[$key]\n";
		if(!defined $$playerstates{$opt{player}[$key]}) {
			print "LMSTTS: Player option $opt{player}[$key] is not a valid MAC address\n"; 
			my $mac = main::search_in_playerstate("Name", $opt{player}[$key]);
			if ($mac) {
				print "LMSTTS: Found player $mac for $opt{player}[$key]\n";
				$opt{player}[$key] = $mac;
			} else {
				print "LMSTTS: Player $opt{player}[$key] not found\n";
			}
		}
	}
	
	$opt{qid} = Time::HiRes::time();
	# $opt{qid} = int(rand(100000));
	{ 
		threads::shared::lock(@ttsqueue);
		push @ttsqueue, \%opt;
	}
	$answer = "LMSTTS: Queued $opt{player}[0]\n";
	
	print $answer;
	
	# sleep 5;
	
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

	
	$cfg=$main::cfg;

	$max_threads_generate_mp3 = $cfg->param("LMSTTS.max_threads_generate_mp3");
	if (! $max_threads_generate_mp3) { $max_threads_generate_mp3=1 };
	my $queue_shutdown_on_idle_sec = $cfg->param("LMSTTS.queue_shutdown_on_idle_sec");
	if (! $queue_shutdown_on_idle_sec) { $queue_shutdown_on_idle_sec = 60; };
	$tts_plugin_hostname = $cfg->param("LMSTTS.tts_plugin_hostname");
	if (! $tts_plugin_hostname) { $tts_plugin_hostname = "localhost:80"; };
	
	
	our $curlm = WWW::Curl::Multi->new; 		# Curl parallel processing object
	# $curlm->setopt(WWW::Curl::Easy::CURLMOPT_MAXCONNECTS, $max_threads_generate_mp3);
	
	
	
	
	my $lastrequest_epoch = time;
	my %saved_states;
		
	$ttsqueue_tid = threads->tid();
	print "TTS queue ($ttsqueue_tid): Created with TID $ttsqueue_tid\n";
		
	
	while( ($lastrequest_epoch+$queue_shutdown_on_idle_sec) > time or @ttsqueue) {
	
		# print "TTS queue ($ttsqueue_tid): " . scalar @ttsqueue . " elements queued (active for " . (time-$lastrequest_epoch) . "s)\n";
		
		# Call the generation of MP3's
		generate_tts_mp3();
		
		
		# Managing queue
		
		# Check if a force 
		
		
		
		$lastrequest_epoch = time if ($curlhandlecount > 0);
		#Time::HiRes::sleep (0.02);
		sleep(1);
	
	}

	print "TTS queue ($ttsqueue_tid): Closing due to inactivity\n";
	$ttsqueue_tid = undef;
	
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
			print "CURL processed $qid (Return value $return_value)\n";
			if ($qid) {
				$curlhandlecount--;
				my $curl_handle = $curlids{$qid};
				$local_queue_data{$qid}{resp_code} = $curl_handle->getinfo(WWW::Curl::Easy::CURLINFO_RESPONSE_CODE);
				delete $curlids{$qid};
				print "generate_tts_mp3 curl Response code: $local_queue_data{$qid}{resp_code}\n";
				# print $local_queue_data{$qid}{curl_response} . "\n";
				
				# Check to have a success response
				if( ! $local_queue_data{$qid}{resp_code} or $local_queue_data{$qid}{resp_code} >= 400 ) {
					$local_queue_data{$qid}{mp3_state} = "failed";
					next;
				}
				
				# Parse json and check if no valid json is given
				# print "RESPONSE: " . $local_queue_data{$qid}{curl_response} . "\n";
				my $json;
				eval {
					$json = JSON::decode_json( $local_queue_data{$qid}{curl_response} );
				};
				if ($@) {
					print "QID $qid: Not a valid JSON file returned\n";
					print $local_queue_data{$qid}{curl_response} . "\n";
					$local_queue_data{$qid}{mp3_state} = "failed";
					next;
				}

				# Read and check content of json 
				$local_queue_data{$qid}{mp3_url} = $json->{'full-httpinterface'};
				$local_queue_data{$qid}{mp3_md5} = $json->{'mp3-filename-MD5'};
				$local_queue_data{$qid}{mp3_duration_ms} = $json->{'duration-ms'};
				
				if(!$local_queue_data{$qid}{mp3_md5} or $local_queue_data{$qid}{mp3_md5} eq "") {
					print "QID $qid: No MD5 hash returned - request seems to have failed";
					$local_queue_data{$qid}{mp3_state} = "failed";
					next;
				}
				
				# We are save
				$local_queue_data{$qid}{mp3_state} = "ready";
				print "MP3-URL: $json->{'full-httpinterface'}\n";
				
				
				
			}
		}
	}

	# Unqueue failed entries
	foreach my $qid (keys %local_queue_data) {
		next if(! defined $local_queue_data{$qid}{mp3_state} or $local_queue_data{$qid}{mp3_state} ne "failed");
		print "Unqueue QID $qid because of failed MP3 conversion\n";
		eval {
			threads::shared::lock(@ttsqueue);
			@ttsqueue = grep { defined $_->{qid} and $_->{qid} ne $qid } @ttsqueue;
		};
		if($@) {
			print "unqueue Exception caught: $@\n";
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
			print "   Element $_->{text} State " . $local_queue_data{$qid}{mp3_state} . "\n";
			
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
			print "Queuing curl TTS interface with qid $qid. URL:\n";
			print "$ttsif_url\n";
			$curlhandlecount++;
			
		}
	}
	# Process parallel curl requests
	
	if($curlhandlecount > 0) {
		$LMSTTS::lastrequest_epoch = time;
		$curlm_active = $LMSTTS::curlm->perform;
		print "Performing curl requests ($curlhandlecount handles, $curlm_active active)\n";
	}
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
