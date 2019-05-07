#!/usr/bin/perl
# Christian Fenzl, christiantf@gmx.at 2017
# This program creates Loxone Virtual In templates for a selected Logitech Media Server Zone.
use strict;
no strict "refs"; # we need it for template system

use lib './lib';

# Own modules
use Basics;

# Perl modules

use Cwd 'abs_path';
use IO::Socket;
use IO::Socket::Timeout;
use URI::Escape;
use POSIX qw/ strftime /;
use HTML::Entities;
use Config::Simple;
use Time::HiRes qw(usleep);
use Switch;
use MIME::Base64;
use CGI qw/:standard/;

# Version of this script
our $version = "0.5.2";

my $home = "/opt/loxberry";
our $tcpout_sock;
our %playerstates;
our @rawparts;
our @parts;
our $line;
our $xmlin;
our $errorstate;
our $errortext;
my $error;

##########################################################################
# Read Settings
##########################################################################

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

# print STDERR "Pluginfolder: $psubfolder";

# Load Configuration from config file
# Read plugin settings
my $cfgfilename = "$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg";
# tolog("INFORMATION", "Reading Plugin config $cfg");
if (! (-e $cfgfilename)) {
	# print header, start_html('Squeezelite Plugin'), h3('The plugin_squeezelite.cfg configuration file could not be found. Please save the settings before opening the Template wizard.'), end_html;
	
	$error .= "The plugin_squeezelite.cfg configuration file could not be found. Please save the settings before opening the Template wizard. <br>\n";
	$errorstate = 1;
	&errors;
	# exit(0);
}

# Read the Plugin config file 
our $cfg = new Config::Simple($cfgfilename);

my $lms2udp_activated = $cfg->param("LMS2UDP.activated");
our $cfgversion = $cfg->param("Main.ConfigVersion");
our $squ_server = $cfg->param("Main.LMSServer");
my $squ_lmswebport = $cfg->param("Main.LMSWebPort");
our $squ_lmscliport = $cfg->param("Main.LMSCLIPort");
my $squ_lmsdataport = $cfg->param("Main.LMSDataPort");
my $lms2udp_msnr = $cfg->param("LMS2UDP.msnr");
my $lms2udp_udpport = $cfg->param("LMS2UDP.udpport");
my $lms2udp_berrytcpport = $cfg->param("LMS2UDP.berrytcpport");
our $lms2udp_usehttpfortext = $cfg->param("LMS2UDP.useHTTPfortext");
my $lms2udp_forcepolldelay = $cfg->param("LMS2UDP.forcepolldelay");
my $lms2udp_refreshdelayms = $cfg->param("LMS2UDP.refreshdelayms");

# Init default values if empty
if (! $squ_lmscliport) { $squ_lmscliport = 9090; }
if (! $lms2udp_berrytcpport) { $lms2udp_berrytcpport = 9092; }
if (! $lms2udp_udpport) { $lms2udp_udpport = 9093; }
if (! $lms2udp_forcepolldelay) { $lms2udp_forcepolldelay = 300; }
if (! $lms2udp_refreshdelayms) { $lms2udp_refreshdelayms = 200000; }

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


# Read Plugin transations
# Read English language as default
# Missing phrases in foreign language will fall back to English	
	
	my $languagefileplugin 	= "$installfolder/templates/plugins/$psubfolder/lang/language_en.ini";
	my $plglang = new Config::Simple($languagefileplugin);
	$plglang->import_names('T');

#	$lang = 'en'; # DEBUG
	
# Read foreign language if exists and not English
	$languagefileplugin = "$installfolder/templates/plugins/$psubfolder/lang/language_$lang.ini";
	 if ((-e $languagefileplugin) and ($lang ne 'en')) {
		# Now overwrite phrase variables with user language
		$plglang = new Config::Simple($languagefileplugin);
		$plglang->import_names('T');
	}
	
#	$lang = 'de'; # DEBUG


# print "MSIP $miniserverip MSPORT $miniserverport LMS $squ_server\n";


if ((! $squ_server) || (! $miniserverip) || (! $miniserverport)) {
	$error .= "Squeezelite Player Plugin LMS2UDP is activated but configuration incomplete. Terminating. <br>\n";
	# unlink $pidfile;
	$errorstate = 1;
}

# This is host and port of the remote machine we are communicating with.
my $tcpout_host = $squ_server;
my $tcpout_port = $squ_lmscliport;
my $udpout_port = $lms2udp_udpport;


# Connection to the remote TCP host
	$tcpout_sock = create_out_socket($tcpout_sock, $tcpout_port, 'tcp', $tcpout_host);

	# No socket, no fun. Exit.
if ($@ || ! $tcpout_sock || ! $tcpout_sock->connected) {

	$errorstate = 1;
	$error .= "Cannot open TCP connection to LMS - Error: $@ <br>\n";
	errors();
}
print $tcpout_sock "players 0\n";
$line = $tcpout_sock->getline;
# Nothing happened - exit!
if (! $line) {
	$errorstate = 1;
	$error .="LMS did not respond with any data. <br>\n";
	&errors;
}
my $local_ip_address = $tcpout_sock->sockhost;
print $tcpout_sock "exit\n";
close $tcpout_sock;
chomp $line;
	
@rawparts = split(/ /, $line);
@parts = split(/ /, $line);
foreach my $part (@parts) {
	$part = uri_unescape($part);
}
if (! players()) {
	# Nothing found;
	$errorstate = 1;
	$error .= "LMS returned no players. <br>\n";
	&errors;
}


$xmlin =  "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
$xmlin .= "<VirtualInUdp Title=\"LMS Gateway\" Comment=\"by LoxBerry Squeezeplayer Plugin\" Address=\"$local_ip_address\" Port=\"$udpout_port\">\n";

   foreach my $player (sort(keys %playerstates)) {
        #print $player, '=', $playerstates{$player}{name}, "\n";
		#print $player, '=', $playerstates{$player}{ip}, "\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} shuffle\" Comment=\"$playerstates{$player}{name} Zufallswiedergabe\" Address=\"\" Check=\"$player playlist shuffle \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"2\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} power\" Comment=\"$playerstates{$player}{name} Power\" Address=\"\" Check=\"$player power \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} repeat\" Comment=\"$playerstates{$player}{name} Wiederholung\" Address=\"\" Check=\"$player playlist repeat \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"2\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} stream\" Comment=\"$playerstates{$player}{name} ist Stream\" Address=\"\" Check=\"$player is_stream \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} sync\" Comment=\"$playerstates{$player}{name} ist synchronisiert\" Address=\"\" Check=\"$player is_synced \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} mode_value\" Comment=\"$playerstates{$player}{name} Modus\" Address=\"\" Check=\"$player mode_value \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} volume\" Comment=\"$playerstates{$player}{name} Lautstärke\" Address=\"\" Check=\"$player mixer volume \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"100\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} muting\" Comment=\"$playerstates{$player}{name} stumm\" Address=\"\" Check=\"$player mixer muting \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} connected\" Comment=\"$playerstates{$player}{name} verbunden\" Address=\"\" Check=\"$player connected \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
	}

$xmlin .= "</VirtualInUdp>\n";
$xmlin .= "</VirtualInUdp>\n";


## Generate output html
########################

our $html;	
  
foreach my $player (sort(keys %playerstates)) {
        #print $player, '=', $playerstates{$player}{name}, "\n";
		#print $player, '=', $playerstates{$player}{ip}, "\n";

	my $outxml = generateOutputTemplate($player);
	
	$html .= 
		'<tr>' . 
		"	<td class=\"tg-vkoh\">$player</td>" . 
		"	<td class=\"tg-031e\">$playerstates{$player}{name}</td>" . 
		"	<td class=\"tg-031e\">$playerstates{$player}{ip}</td>" . 
		"	<!-- <td class=\"tg-s6z2\">$playerstates{$player}{connected}</td> -->" . 
		"	<td class=\"tg-vkoh\"> " . 
	#	"<input type=\"text\" value=\"$player name\">" .
	#	"<input type=\"text\" value=\"$player title\">" .
	#	"<input type=\"text\" value=\"$player mode\">" .
		"LMS $player name<br />" .
		"LMS $player title<br />" .
		"LMS $player mode" .
		'</td>' .
		'<td class=\"tg-031e\">' . 
		"<center><a download=\"VO_LMS_Zone_$playerstates{$player}{name}.xml\"title=\"$T::TEMPLATEBUILDER_OUTPUT_TEMPLATE_FOR_ZONE $playerstates{$player}{name}\" data-role=\"button\" data-icon=\"arrow-r\" data-iconpos=\"notext\" href=\"data:application/octet-stream;charset=utf-8;base64,$outxml\" ></a><center>" .
		'</td>' .
		'</tr>';
  }

$xmlin = encode_base64($xmlin);

############################################
# Print Page 
############################################

print "Content-Type: text/html\n\n";
my $template_title = "Squeezelite Player Plugin";
# Print Header
&lbheader;

# Print TEMPLATEBUILDER 
			
open(F,"$installfolder/templates/plugins/$psubfolder/multi/templatebuilder.html") || die "Missing template plugins/$psubfolder/multi/templatebuilder.html";
 while (<F>) 
	{
	    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
#	    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		print $_;
	}
close(F);
	
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
			}
		}
	}
	if (! $curr_player) {
		return undef;
	} else {
		return $playercount;
	}
}

	
sub generateOutputTemplate 

{

our ($player) = @_;
our $playername = $playerstates{$player}{name};
print STDERR "Creating Output template for player $player\n";

open(F, "$installfolder/templates/plugins/$psubfolder/multi/virtualout.xml") or print STDERR "Missing VirtualOut template templates/plugins/$psubfolder/multi/virtualout.xml";
my $xml;
 while (<F>) 
	{
	    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		$xml .= $_;
	}
close(F);
return encode_base64($xml);
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
		close($socket);
	}
		
	$socket = IO::Socket::INET->new( %params )
		or return undef; 
#		{ #$Error = "Couldn't connect to $remotehost:$port : $@\n";
#		 return undef;
#		};
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


####### LBHeader ########
sub lbheader 
	{
		 # Create Help page
	  my $helplink = "http://www.loxwiki.eu:80/x/_4Cm";
	  
	  	
	# Read Plugin Help transations
	# Read English language as default
	# Missing phrases in foreign language will fall back to English	
	
	open(F,"$installfolder/templates/system/$lang/header.html") || die "Missing template system/$lang/header.html";
	while (<F>) 
		{
	      $_ =~ s/<!--\$(.*?)-->/${$1}/g;
	      print $_;
	    }
	  close(F);
	}

sub errors
{

# lbheader();
	print header, start_html("Squeezelite Plugin - Errors occured");
	&lbheader;
	print STDERR "Hallo\n";
	print "<h3>The Template Generator found errors therefore cannot be displayed:</h3>";
	print $error;
	print "<h3>Please try to fix it, and try it again.</h3>";
	print end_html;
exit;
}