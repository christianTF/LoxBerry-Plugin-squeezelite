#!/usr/bin/perl

# Copyright 2017 Christian Fenzl, christiantf@gmx.at
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


##########################################################################
# Modules
##########################################################################

# Own modules
use lib './lib';
use Basics;


use POSIX 'strftime';
use CGI::Carp qw(fatalsToBrowser);
use CGI qw/:standard/;
use Config::Simple;
use File::HomeDir;
use Cwd 'abs_path';
# use Net::Address::Ethernet qw( get_address );
use warnings;
use strict;

no strict "refs"; # we need it for template system

##########################################################################
# Variables
##########################################################################

# Version of this script
our $version = "0.5.2";

our $cfg;
our $phrase;
our $namef;
our $value;
our %query;
our $template_title;
our $help;
our @help;
our $helptext;
our $helplink;
our $languagefile;
our $error;
our $saveformdata=0;
our $output;
our $message;
our $nexturl;

our $doapply;
our $doadd;
our $dodel;

my  $home = File::HomeDir->my_home;
our $pname;
our $debug=1;
our $languagefileplugin;
our $phraseplugin;
our $plglang;

our $selectedverbose;
our $selecteddebug;
our $header_already_sent=0;

our $cfgfilename;
our $cfgversion=0;
our $cfg_version;
our $squ_instances=0;
our $squ_server;
our $squ_lmswebport;
our $squ_lmscliport;
our $squ_lmsdataport;

our $lms2udp_activated;
our $lms2udp_msnr;
our $lms2udp_udpport;
our $lms2udp_berrytcpport;

our $squ_debug;
our $lmslinks;
our $squ_debug_enabled;
our $instance;
our $enabled;
our $runningInstances;
our @inst_enabled;
our @inst_name;
our @inst_desc;
our @inst_mac;
our @inst_output;
our @inst_params;
our @commandline;
our $htmlout;

our %cfg_mslist;

my $logname;
my $loghandle;
my $logmessage;


##########################################################################
# Read Settings
##########################################################################

# Figure out in which subfolder we are installed
my $part = substr ((abs_path($0)), (length($home)+1));
our ($psubfolder) = (split(/\//, $part))[3];
our $pluginname = $psubfolder;

# Read global settings
my  $syscfg             = new Config::Simple("$home/config/system/general.cfg");
our $installfolder   = $syscfg->param("BASE.INSTALLFOLDER");
our $lang            = $syscfg->param("BASE.LANG");
our $miniservercount = $syscfg->param("BASE.MINISERVERS");
our $clouddnsaddress = $syscfg->param("BASE.CLOUDDNS");

# Initialize logfile
if ($debug) {
	$logname = "$installfolder/log/plugins/$psubfolder/lms2udp_cgi.log";
	open ($loghandle, '>>' , $logname); # or warn "Cannot open logfile for writing (Permission?) - Continuing without log\n";
	chmod (0666, $loghandle); # or warn "Cannot change logfile permissions\n";	
}

# Read plugin settings
$cfgfilename = "$installfolder/config/plugins/$psubfolder/plugin_squeezelite.cfg";
tolog("INFORMATION", "Reading Plugin config $cfgfilename");
if (-e $cfgfilename) {
	tolog("INFORMATION", "Plugin config existing - loading");
	$cfg = new Config::Simple($cfgfilename);
}
unless (-e $cfgfilename) {
	tolog("INFORMATION", "Plugin config NOT existing - creating");
	$cfg = new Config::Simple(syntax=>'ini');
	$cfg->param("Main.ConfigVersion", 2);
	$cfg->write($cfgfilename);
}


#########################################################################
# Parameter
#########################################################################

# For Debugging with level 3 
sub apache()
{
  if ($debug eq 3)
  {
		if ($header_already_sent eq 0) {$header_already_sent=1; print header();}
		my $debug_message = shift;
		# Print to Browser 
		print $debug_message."<br>\n";
		# Write in Apache Error-Log 
		print STDERR $debug_message."\n";
	}
	return();
}

# Everything from URL
foreach (split(/&/,$ENV{'QUERY_STRING'}))
{
  ($namef,$value) = split(/=/,$_,2);
  $namef =~ tr/+/ /;
  $namef =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
  $value =~ tr/+/ /;
  $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
  $query{$namef} = $value;
}

# Set parameters coming in - get over post

	if 	( param('applybtn') ) 	{ $doapply = 1; }
	
# Clean up saveformdata variable
	$saveformdata =~ tr/0-1//cd; $saveformdata = substr($saveformdata,0,1);

# Read Plugin transations
# Read English language as default
# Missing phrases in foreign language will fall back to English	
	
	$languagefileplugin 	= "$installfolder/templates/plugins/$psubfolder/lang/language_en.ini";
	$plglang = new Config::Simple($languagefileplugin);
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
	
##########################################################################
# Main program
##########################################################################

	if ($doapply) 
	{
		tolog("DEBUG", "LMS2UDP - save form and restart");
		&save;
		&restartLMS2UDP; 
	}
	tolog("DEBUG", "form triggered - load form");
	&form;
	
	exit;

#####################################################
# 
# Subroutines
#
#####################################################

#####################################################
# Form-Sub
#####################################################

	sub form 
	{
		# Filter
		# $debug     = quotemeta($debug);
		tolog("INFORMATION", "save triggered - save, refresh form");
							
		# Read the Main config file section
		$cfgversion = $cfg->param("Main.ConfigVersion");
		$squ_server = $cfg->param("Main.LMSServer");
		$squ_lmswebport = $cfg->param("Main.LMSWebPort");
		$squ_lmscliport = $cfg->param("Main.LMSCLIPort");
		$squ_lmsdataport = $cfg->param("Main.LMSDataPort");
		
		$lms2udp_activated = $cfg->param("LMS2UDP.activated");
		$lms2udp_msnr = $cfg->param("LMS2UDP.msnr");
		$lms2udp_udpport = $cfg->param("LMS2UDP.udpport");
		$lms2udp_berrytcpport = $cfg->param("LMS2UDP.berrytcpport");

		$squ_debug = $cfg->param("Main.debug");
		if (is_true($squ_debug)) {
			$squ_debug_enabled = 'checked';
			# $debug = 1;
		} else {
			$squ_debug_enabled = '';
			# $debug = 0;
		}

		if (is_true($lms2udp_activated)) {
			$lms2udp_activated = 'checked';
			# $debug = 1;
		} else {
			$lms2udp_activated = '';
			# $debug = 0;
		}
		
		# Read labels from config
		# If the labels are empty, set them to the language default labels
		our $lms2udp_disconnected = defined $cfg->param("LMS2UDP.ZONELABEL_Disconnected") ? $cfg->param("LMS2UDP.ZONELABEL_Disconnected") : $T::LMS2UDP_ZONELABEL_DISCONNECTED;
		our $lms2udp_poweredoff = defined $cfg->param("LMS2UDP.ZONELABEL_Poweredoff") ? $cfg->param("LMS2UDP.ZONELABEL_Poweredoff") : $T::LMS2UDP_ZONELABEL_POWEREDOFF;
		our $lms2udp_stopped = defined $cfg->param("LMS2UDP.ZONELABEL_Stopped") ? $cfg->param("LMS2UDP.ZONELABEL_Stopped") : $T::LMS2UDP_ZONELABEL_STOPPED;
		our $lms2udp_paused = defined $cfg->param("LMS2UDP.ZONELABEL_Paused") ? $cfg->param("LMS2UDP.ZONELABEL_Paused") : $T::LMS2UDP_ZONELABEL_PAUSED;
		our $lms2udp_playing = defined $cfg->param("LMS2UDP.ZONELABEL_Playing") ? $cfg->param("LMS2UDP.ZONELABEL_Playing") : $T::LMS2UDP_ZONELABEL_PLAYING;
		
		# Generate links to LMS and LMS settings $lmslink and $lmssettingslink in topmenu
		if ($squ_server) {
			my $webport = 9000;
			if ($squ_lmswebport) {
				$webport = $squ_lmswebport;
			} 
			$lmslinks = "				<li><a target=\"_blank\" href=\"http://$squ_server:$webport/\">Logitech Media Server</a></li>\n" . 
						"				<li><a target=\"_blank\" href=\"http://$squ_server:$webport/settings/index.html\">LMS Settings</a></li>";
		}
	
		if (! $lms2udp_msnr) {
			$lms2udp_msnr = 1;
		}
		
		# HTML Miniserver
		our $html_miniserver;
		if ($miniservercount > 1) {
			$html_miniserver = 
				'	  <tr>' . 
				'		<td style="border-width : 0px;"><!--$T::LMS2UDP_MSNR--></td>' . 
				'		<td style="border-width : 0px;">' .
				'			<select name="Miniserver">';
			for (my $msnr = 1; $msnr <= $miniservercount; $msnr++) {
				if ($msnr == $lms2udp_msnr) {
					$html_miniserver .= '				<option value="' . $msnr . '" selected>' . $syscfg->param("MINISERVER$msnr.NAME") . " (" . $syscfg->param("MINISERVER$msnr.IPADDRESS") . ')</option>';
				} else {
					$html_miniserver .= '				<option value="' . $msnr . '">' . $syscfg->param("MINISERVER$msnr.NAME") . " (" . $syscfg->param("MINISERVER$msnr.IPADDRESS") . ')</option>';
				}
			}
			
			$html_miniserver .= 
				'		</td>' .
				'		<td style="border-width : 0px;"><!--$T::LMS2UDP_MSNR_FORMAT--></td>' .
				'	  </tr>';
	  	}
		else {
					$html_miniserver .= '			<input type="hidden" name="Miniserver" value="1">';
		}
	
		if ( !$header_already_sent ) { print "Content-Type: text/html\n\n"; }
		
		#$template_title = $phrase->param("TXT0000") . ": " . $phrase->param("TXT0040");
		$template_title = "Squeezelite Player Plugin";
		
		# Print Header
		&lbheader;
		
		# Print Menu selection
		our $class_lms2udp = 'class="ui-btn-active ui-state-persist"';
		open(F,"$installfolder/templates/plugins/$psubfolder/multi/topmenu.html") || die "Missing template plugins/$psubfolder/multi/topmenu.html";
		  while (<F>) 
		  {
		    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    print $_;
		  }
		close(F);
		
		# Print LMS2UDP setting
			
		open(F,"$installfolder/templates/plugins/$psubfolder/multi/lms2udp.html") || die "Missing template plugins/$psubfolder/multi/lms2udp.html";
		  while (<F>) 
		  {
		    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    print $_;
		  }
		close(F);
		&footer;
		exit;
	}

#####################################################
# Save-Sub
#####################################################

	sub save 
	{
		
		# Read global plugin values from form and write to config
		
		# Hidden form fields
		$cfg_version 		= trim(param('ConfigVersion'));
		$squ_debug			= trim(param('debug'));
		
		# Visible form fields
		$lms2udp_activated 	= trim(param("LMS2UDP_activated"));
		$lms2udp_msnr 		= trim(param("Miniserver"));
		$lms2udp_udpport 	= trim(param("UDPPORT"));
		$squ_server			= trim(param('LMSServer'));
		$squ_lmswebport 	= trim(param("LMSWebPort"));
		$squ_lmscliport 	= trim(param("LMSCLIPort"));
		$squ_lmsdataport 	= trim(param("LMSDATAPort"));
		$lms2udp_berrytcpport = trim(param("LOXBERRYPort"));
		
		$cfg->param("Main.ConfigVersion", $cfg_version);
		$cfg->param("LMS2UDP.activated", $lms2udp_activated);
		$cfg->param("Main.LMSServer", $squ_server);
		$cfg->param("Main.LMSWebPort", $squ_lmswebport);
		$cfg->param("Main.LMSCLIPort", $squ_lmscliport);
		$cfg->param("Main.LMSDataPort", $squ_lmsdataport);
		$cfg->param("LMS2UDP.msnr", $lms2udp_msnr);
		$cfg->param("LMS2UDP.udpport", $lms2udp_udpport);
		$cfg->param("LMS2UDP.berrytcpport", $lms2udp_berrytcpport);
		
		$cfg->param("LMS2UDP.ZONELABEL_Disconnected", param("LMS2UDP_Disconnected"));
		$cfg->param("LMS2UDP.ZONELABEL_Poweredoff", param("LMS2UDP_Poweredoff"));
		$cfg->param("LMS2UDP.ZONELABEL_Stopped", param("LMS2UDP_Stopped"));
		$cfg->param("LMS2UDP.ZONELABEL_Paused", param("LMS2UDP_Paused"));
		$cfg->param("LMS2UDP.ZONELABEL_Playing", param("LMS2UDP_Playing"));
				
		if ($squ_debug) {
			$cfg->param("Main.debug", "Yes");
		} else {
			$cfg->param("Main.debug", "False");
		}
		
		$cfg->save();
	
	}

	
	
	
#####################################################
# Restart-Sub
#####################################################
	
	sub restartLMS2UDP
	{
		
		my $restartscript = "$installfolder/webfrontend/cgi/plugins/$psubfolder/restart_lms2udp.sh 1> /dev/null 2> $home/log/plugins/$psubfolder/lms2udp.log &";
		system($restartscript);
		return;
	}
	
	
#####################################################
# Error-Sub
#####################################################

	sub error 
	{
		$template_title = "Squeezelite Player : Error";
		if ( !$header_already_sent ) { print "Content-Type: text/html\n\n"; }
		&lbheader;
		open(F,"$installfolder/templates/system/$lang/error.html") || die "Missing template system/$lang/error.html";
    while (<F>) 
    {
      $_ =~ s/<!--\$(.*?)-->/${$1}/g;
      print $_;
    }
		close(F);
		&footer;
		exit;
	}

#####################################################
# Page-Header-Sub
#####################################################

	sub lbheader 
	{
		 # Create Help page
	  $helplink = "http://www.loxwiki.eu:80/x/_4Cm";
	  
	  	
	# Read Plugin Help transations
	# Read English language as default
	# Missing phrases in foreign language will fall back to English	
	
	$languagefileplugin	= "$installfolder/templates/plugins/$psubfolder/lang/help_en.ini";
	$plglang = new Config::Simple($languagefileplugin);
	$plglang->import_names('T');

	# Read foreign language if exists and not English
	$languagefileplugin = "$installfolder/templates/plugins/$psubfolder/lang/help_$lang.ini";
	 if ((-e $languagefileplugin) and ($lang ne 'en')) {
		# Now overwrite phrase variables with user language
		$plglang = new Config::Simple($languagefileplugin);
		$plglang->import_names('T');
	}
	  
	# Parse help template
	open(F,"$installfolder/templates/plugins/$psubfolder/multi/help_lms2udp.html") || die "Missing template plugins/$psubfolder/multi/help_lms2udp.html";
		while (<F>) {
			$_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    $helptext = $helptext . $_;
		}
	close(F);
	open(F,"$installfolder/templates/system/$lang/header.html") || die "Missing template system/$lang/header.html";
	while (<F>) 
		{
	      $_ =~ s/<!--\$(.*?)-->/${$1}/g;
	      print $_;
	    }
	  close(F);
	}

#####################################################
# Footer
#####################################################

	sub footer 
	{
	  open(F,"$installfolder/templates/system/$lang/footer.html") || die "Missing template system/$lang/footer.html";
	    while (<F>) 
	    {
	      $_ =~ s/<!--\$(.*?)-->/${$1}/g;
	      print $_;
	    }
	  close(F);
	}


#####################################################
# Lokale MAC-Adresse auslesen
#####################################################

sub getMAC {

  use IO::Socket;
  use IO::Interface qw(:flags);

  my $s = IO::Socket::INET->new(Proto => 'udp');
  my @interfaces = $s->if_list;
  my $mac;
  
  for my $if (@interfaces) {
    my $flags = $s->if_flags($if);
    
	if ( ($flags & IFF_RUNNING) and ( $flags & IFF_BROADCAST ) and ($s->if_hwaddr($if) ne '00:00:00:00:00:00' ) ) {
		$mac =  $s->if_hwaddr($if);
		# print $mymac;
		last;
	}
  }

  return $mac;
}


#####################################################
# Logging
#####################################################

sub tolog 
{
	if ($loghandle) {
		print $loghandle strftime("%Y-%m-%d %H:%M:%S", localtime(time)) . " $_[0]: $_[1]\n";
	}
}
