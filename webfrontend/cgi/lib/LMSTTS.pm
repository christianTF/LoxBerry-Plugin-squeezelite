use forks;
use forks::shared;
use strict;

package LMSTTS;

# $guest_answer = LMSTTS::tts($tcpout_sock, \@guest_params, \%playerstates);

our $ttsqueue_tid : shared = undef;
our $ttsqueue_thr;
our @ttsqueue : shared;

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
	
	push @ttsqueue, \%opt;
	
	$answer = "LMSTTS: Queued $opt{player}[0]\n";
	
	print $answer;
	
	# sleep 5;
	
	return $answer;

}


##################################################
# TTS Queue
##################################################

sub tts_queue
{

	my $lastrequest_epoch = time;
	
	$ttsqueue_tid = threads->tid();
	print "TTS queue ($ttsqueue_tid): Created with TID $ttsqueue_tid\n";
	
	while(($lastrequest_epoch+300) > time) {
	
		print "TTS queue ($ttsqueue_tid): " . scalar @ttsqueue . " elements queued (active for " . (time-$lastrequest_epoch) . "s)\n";
		
		# Managing queue
		
		# Check if a force 
		
		
		
		
		sleep(3);
	
	}

	print "TTS queue ($ttsqueue_tid): Closing due to inactivity\n";
	$ttsqueue_tid = undef;
	
	return;
	
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
