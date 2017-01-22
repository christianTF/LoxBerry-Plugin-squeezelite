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

my $home = "/opt/loxberry";
our $tcpout_sock;
our %playerstates;
our @rawparts;
our @parts;
our $line;
our $xmlin;
our $errorstate;
our $errortext;

##########################################################################
# Read Settings
##########################################################################

# Version of this script
our $version = "0.3.2";

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
	print STDERR "Squeezelite Player Plugin Konfiguration ist nicht vollständig. Bitte vor dem Starten des Assistenten die Konfiguration speichern.\n";
	$errorstate = 1;
	# exit(0);
}

# Read the Plugin config file 
our $cfg = new Config::Simple($cfgfilename);

my $lms2udp_activated = $cfg->param("LMS2UDP.activated");
our $cfgversion = $cfg->param("Main.ConfigVersion");
our $squ_server = $cfg->param("Main.LMSServer");
my $squ_lmswebport = $cfg->param("Main.LMSWebPort");
my $squ_lmscliport = $cfg->param("Main.LMSCLIPort");
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

# print "MSIP $miniserverip MSPORT $miniserverport LMS $squ_server\n";


if ((! $squ_server) || (! $miniserverip) || (! $miniserverport)) {
	print STDERR "Squeezelite Player Plugin LMS2UDP is activated but configuration incomplete. Terminating.\n";
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
if (! $tcpout_sock->connected) {
	$errorstate = 1;
}
print $tcpout_sock "players 0\n";
$line = $tcpout_sock->getline;
# Nothing happened - exit!
if (! $line) {
	$errorstate = 1;
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
	exit(1);
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
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} mode_value\" Comment=\"$playerstates{$player}{name} Modus\" Address=\"\" Check=\"$player mode_value \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} volume\" Comment=\"$playerstates{$player}{name} Lautstärke\" Address=\"\" Check=\"$player mixer volume \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"100\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} muting\" Comment=\"$playerstates{$player}{name} stumm\" Address=\"\" Check=\"$player mixer muting \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
		$xmlin .= "\t<VirtualInUdpCmd Title=\"$playerstates{$player}{name} connected\" Comment=\"$playerstates{$player}{name} verbunden\" Address=\"\" Check=\"$player connected \\v\" Signed=\"true\" Analog=\"true\" SourceValLow=\"0\" DestValLow=\"0\" SourceValHigh=\"100\" DestValHigh=\"100\" DefVal=\"0\" MinVal=\"0\" MaxVal=\"1\"/>\n";
	}

$xmlin .= "</VirtualInUdp>\n";
$xmlin .= "</VirtualInUdp>\n";


## Generate output html
########################
# <html class="ui-mobile">
# <head>
	# <title>Squeezelite Player Plugin</title>
	# <meta http-equiv="content-type" content="text/html; charset=utf-8">
	# <link rel="stylesheet" href="/system/scripts/jquery/themes/main/loxberry.min.css">
	# <link rel="stylesheet" href="/system/scripts/jquery/themes/main/jquery.mobile.icons.min.css">
	# <link rel="stylesheet" href="/system/scripts/jquery/jquery.mobile.structure-1.4.5.min.css">
	# <link rel="stylesheet" href="/system/css/main.css">
	# <link rel="shortcut icon" href="/system/images/icons/favicon.ico">
	# <link rel="icon" type="image/png" href="/system/images/favicon-32x32.png" sizes="32x32">
	# <link rel="icon" type="image/png" href="/system/images/favicon-16x16.png" sizes="16x16">
	# <script src="/system/scripts/jquery/jquery-1.8.2.min.js"></script>
	# <script src="/system/scripts/jquery/jquery.mobile-1.4.5.min.js"></script>
	# <script src="/system/scripts/form-validator/jquery.form-validator.min.js"></script>
	# <script src="/system/scripts/setup.js"></script>
	# <script>
			# // Disable JQUERY ♢OM Caching
			# $.mobile.page.prototype.options.domCache = false;
			# $(document).on("pagehide", "div[data-role=page]", function(event)
			# {
				# $(event.target).remove();
			# });
			# // Disable caching of AJAX responses
			# $.ajaxSetup ({ cache: false });
	# </script>
	# </head>
	# <body class="ui-mobile-viewport ui-overlay-a">
		# <div id="lang" style="display: none">de</div>

our $html;	
# $html = '<link rel="stylesheet" href="/plugins/' . $pluginname . '/style.css">' . 
		# '<script>$(document).ready(function(){ ' .
		# ' $("#btnmainmenu").hide(); ' . 
		# ' $("#btninfo").hide(); ' . 
		# '});' .
		# '</script>';
# $html .=
# '<style type="text/css">
# .tg  {border-collapse:collapse;border-spacing:0;margin:0px auto;}
# .tg td{font-family:Arial, sans-serif;font-size:14px;padding:10px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;}
# .tg th{font-family:Arial, sans-serif;font-size:14px;font-weight:normal;padding:10px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;}
# .tg .tg-s6z2{text-align:center}
# .tg .tg-e3zv{font-weight:bold}
# .tg .tg-vkoh{font-family:"Lucida Console", Monaco, monospace !important;}
# .tg .tg-hgcj{font-weight:bold;text-align:center}
# @media screen and (max-width: 767px) {.tg {width: auto !important;}.tg col {width: auto !important;}.tg-wrap {overflow-x: auto;-webkit-overflow-scrolling: touch;margin: auto 0px;}}</style>
# <div class="tg-wrap">';

# $html .='<table class="tg" style="undefined;table-layout: fixed; width: 782px">' .
		# '<colgroup>
		# <col style="width: 120px">
		# <col style="width: 186px">
		# <col style="width: 134px">
		# <!-- <col style="width: 86px"> -->
		# <col style="width: 200px">
		# </colgroup>' .
		# '	<tr>' .
		# '		<th class="tg-e3zv">Player-MAC</th>' . 
		# '		<th class="tg-e3zv">Name</th>' .
		# '		<th class="tg-e3zv">IP</th>' .
		# '		<!-- <th class="tg-hgcj">Verbunden</th> -->'.
		# '		<th class="tg-e3zv">Virtuelle Texteingänge<br>(manuell erzeugen)</th>' .
		# '		</tr>';
  
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
		"<center><a download=\"VO_LMS_Zone_$playerstates{$player}{name}\"title=\"Ausgangs-Template für Zone $playerstates{$player}{name}\" data-role=\"button\" data-icon=\"arrow-r\" data-iconpos=\"notext\" href=\"data:application/octet-stream;charset=utf-8;base64,$outxml\" ></a><center>" .
		'</td>' .
		'</tr>';
  }
  
# $html .= '</table></div>';

# $html .= '<br />' .
		 # '<center><button type="submit" tabindex="-1" form="main_form" name="applybtn" value="apply" id="btntemplate" data-role="button" data-inline="true" data-mini="true" data-icon="grid">Template-Download</button></center>';

# $html .= '<script>' .
		# '$("#btntemplate").click(function() {' .
		# '  window.location = "data:application/octet-stream;charset=utf-8;base64,' .
		# encode_base64($xmlin) .
		# '"});' . 
		# '</script>';

# $html .= '<br /><center><a download="VIU_LMSGateway.xml" href="data:application/octet-stream;charset=utf-8;base64,' ;

$xmlin = encode_base64($xmlin);

# $html .='">Download VirtualIn-UDP Template</a><br /><br />' .
		# 'Speichern unter:  C:\ProgramData\Loxone\Loxone Config <i>version</i>\Templates\VirtualIn\<b>VIU_LMSGateway.xml</b><br />' .
		# '<i>Der Dateiname muss unbedingt mit <b>VIU_</b> beginnen!</i> Danach Loxone Config neu starten.<br />' .
		# 'Details findest du in der <a target="_blank" href="http://www.loxwiki.eu:80/x/_4Cm#SqueezelitePlayer-templategeneratorEingangs-Assistent">Anleitung im LoxBerry Wiki</a>.' .
		# '<center>';

		
print "Content-Type: text/html\n\n";
my $template_title = "Squeezelite Player Plugin";
# Print Header
&lbheader;

# Print TEMPLATEBUILDER setting
			
open(F,"$installfolder/templates/plugins/$psubfolder/multi/templatebuilder.html") || die "Missing template plugins/$psubfolder/multi/templatebuilder.html";
 while (<F>) 
	{
	    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
#	    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		print $_;
	}
close(F);



# print $html;

# print 	'</body>' .
		# '</html>';
	
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

my ($player) = @_;

print STDERR "Creating Output template for player $player\n";

my $xml = 
	"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" .
	"<VirtualOut Title=\"LMS $playerstates{$player}{name}\" Comment=\"by LoxBerry Squeezelite Player Plugin\" Address=\"tcp://$squ_server:$squ_lmscliport\" CmdInit=\"$player \" CloseAfterSend=\"true\" CmdSep=\"\">" . '
	<VirtualOutCmd Title="Play" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="play \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Stop" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="stop \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Pause" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="pause \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Poweroff" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="power 0 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Poweron" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="power 1 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Skip Next" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist index +1 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Skip Previous" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist index -1 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Volume" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="mixer volume &lt;v&gt; \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="true" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Volume Up" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="mixer volume +1 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Volume Down" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="mixer volume -1 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Mute" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="mixer muting toggle \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Shuffle On" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist shuffle 1 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Shuffle Off" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist shuffle 0 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Shuffle Toggle" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist shuffle \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play Random Songs" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="randomplay tracks \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Seek +10s" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="time +10 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Seek -10s" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="time -10 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Sleeptimer 1 Hour" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="sleep 3600 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Sync to <player>" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="sync <player:mac> \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Sync off" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="sync - \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Doorbell Start" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist preview url:C:\music\Kalimba.mp3 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Doorbell Stop" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist preview cmd:stop \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play Favorite 1" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="favorites playlist play item_id:1 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play Favorite 2" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="favorites playlist play item_id:2 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play Favorite 3" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="favorites playlist play item_id:3 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play Favorite 4" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="favorites playlist play item_id:4 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play Favorite 5" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="favorites playlist play item_id:5 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play specific folder" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist play /path/to/your/folder \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play specific artist" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist loadalbum * Abba * \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Play specific genre" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist loadalbum Pop * * \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="MusicIP Mood ItaloDance" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="musicip mood:ItaloDance \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Playlist Hitradio Ö3" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist play http://opml.radiotime.com/Tune.ashx?id=s8007&amp;formats=aac,ogg,mp3,wmpro,wma,wmvoice&amp;partnerId=16&amp;serial=50e8f023e07550d9a6bafb389f370415 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Playlist Life Radio" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist play http://opml.radiotime.com/Tune.ashx?id=s15592&amp;formats=aac,ogg,mp3,wmpro,wma,wmvoice&amp;partnerId=16&amp;serial=f0825444fcd3ba53b49c12c1a02f16f8 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Playlist Welle 1" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist play http://opml.radiotime.com/Tune.ashx?id=s254362&amp;formats=aac,ogg,mp3,wmpro,wma,wmvoice&amp;partnerId=16&amp;serial=977e69e221e1df668964da983ff434f5 \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/>
	<VirtualOutCmd Title="Playlist Happy FM" Comment="" CmdOnMethod="GET" CmdOffMethod="GET" CmdOn="playlist play http://opml.radiotime.com/Tune.ashx?id=s152262&amp;formats=aac,ogg,mp3,wmpro,wma,wmvoice&amp;partnerId=16&amp;serial=ba366d4226553a750c41b58b859155dc&amp;filter=s:popular \n" CmdOnHTTP="" CmdOnPost="" CmdOff="" CmdOffHTTP="" CmdOffPost="" Analog="false" Repeat="0" RepeatRate="0"/> ' .
	"\n</VirtualOut>";
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
