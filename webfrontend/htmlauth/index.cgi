#!/usr/bin/perl

# Copyright 2016-2017 Christian Fenzl, christiantf@gmx.at
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

use LoxBerry::System;
use LoxBerry::Web;
use LoxBerry::Log;
use CGI::Carp qw(fatalsToBrowser);
use CGI qw/:standard/;
use Config::Simple;
# use Net::Address::Ethernet qw( get_address );

use warnings;
use strict;
no strict "refs"; # we need it for template system

##########################################################################
# Variables
##########################################################################

# Version of this script
our $version = "1.0.7.1";

our $cfg;
our $namef;
our $value;
our %query;
our $lang;
our $template_title;
our $help;
our @help;
our $helptext;
our $helplink;
our $installfolder;
our $languagefile;
our $saveformdata=0;
our $output;
our $message;
our $nexturl;

our $doapply;
our $doadd;
our $dodel;

our $pname;
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

our $squ_debug;
our $squ_poweroff;
our $squ_altbinaries;
our $lmslinks;
our $squ_debug_enabled;
our $squ_poweroff_enabled;
our $squ_altbinaries_enabled;
our $instance;
our $enabled;
our $runningInstances;
our @inst_enabled;
our @inst_name;
our @inst_desc;
our @inst_mac;
our @inst_output;
our @inst_params;
our @inst_alsacontrol;
our @inst_alsavolume;
our @commandline;
our $htmlout;

my $logname;
my $loghandle;
my $logmessage;

our $logfileslink;

# Init logfile
my $log = LoxBerry::Log->new (
    name => 'Webinterface',
	addtime => 1,
);

LOGSTART("index.cgi");

##########################################################################
# Read Settings
##########################################################################

# Figure out in which subfolder we are installed
our $psubfolder = $lbpplugindir;

# Read global settings

#$cfg = new Config::Simple("$lbsconfigdir/general.cfg");
$installfolder = $lbhomedir;
$lang = LoxBerry::System::lblanguage();

# Read plugin settings
$cfgfilename = "$lbpconfigdir/plugin_squeezelite.cfg";
LOGINF("Reading Plugin config $cfgfilename");
if (-e $cfgfilename) {
	LOGOK("Plugin config existing - loading");
	$cfg = new Config::Simple($cfgfilename);
}
unless (-e $cfgfilename) {
	LOGOK("Plugin config NOT existing - creating");
	$cfg = new Config::Simple(syntax=>'ini');
	$cfg->param("Main.ConfigVersion", 2);
	$cfg->param("Main.ConfigVersion", 2);
	$cfg->param("Main.PoweroffPlayers", 0);
	$cfg->param("Main.UseAlternativeBinaries", 1);
	$cfg->write($cfgfilename);
}

#########################################################################
# Parameter
#########################################################################

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
# Don't know why this is so complicated...
	if ( !$query{'saveformdata'} ) { if ( param('saveformdata') ) { $saveformdata = quotemeta(param('saveformdata')); } else { $saveformdata = 0;      } } else { $saveformdata = quotemeta($query{'saveformdata'}); }

	if 	( param('applybtn') ) 	{ $doapply = 1; }
	elsif ( param('addbtn') ) 	{ $doadd = 1; }
	elsif ( param('delbtn') )	{ $dodel = 1; }
	
	
# Clean up saveformdata variable
	$saveformdata =~ tr/0-1//cd; $saveformdata = substr($saveformdata,0,1);

# Read Plugin transations
# Read English language as default
# Missing phrases in foreign language will fall back to English	
	
	$languagefileplugin 	= "$lbptemplatedir/lang/language_en.ini";
	$plglang = new Config::Simple($languagefileplugin);
	$plglang->import_names('T');

# Read foreign language if exists and not English
	$languagefileplugin = "$lbptemplatedir/lang/language_$lang.ini";
	 if ((-e $languagefileplugin) and ($lang ne 'en')) {
		# Now overwrite phrase variables with user language
		$plglang = new Config::Simple($languagefileplugin);
		$plglang->import_names('T');
	}
	
#	$lang = 'de'; # DEBUG
	
##########################################################################
# Main program
##########################################################################

	if ($saveformdata) 
	{
		if ($doapply) 		{ 	LOGINF("doapply triggered - save, restart, refresh form");
									&save;
									&restartSqueezelite; }
		elsif ($doadd)	{ 	LOGINF("doaadd triggered - save with +1, refresh form");
							&save(1); }
		elsif ($dodel)	{ 	LOGINF("doadel triggered - save with -1, refresh form");
							&save(-1); }
		else { 				LOGINF( "save triggered - save, refresh form");
							&save; }
	  &form;
	}
	else 
	{
	  LOGINF("form triggered - load form");
	  &form;
	}
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
		LOGINF("save triggered - save, refresh form");
		
		# Query Squeezelite binary
		my $sl_path = sl_path();
		
		# Prepare form defaults
		# Read Squeezelite possible sound outputs
		LOGOK("Calling squeezelite to get outputs");
		my $squ_outputs = `$sl_path -l` or LOGERR("Failed to run squeezelite.");
		LOGDEB("$squ_outputs");
		# Sample output:

# Output devices:
#  null                           - Discard all samples (playback) or generate zero samples (capture)
#  default:CARD=ALSA              - bcm2835 ALSA, bcm2835 ALSA - Default Audio Device
#  sysdefault:CARD=ALSA           - bcm2835 ALSA, bcm2835 ALSA - Default Audio Device
#  dmix:CARD=ALSA,DEV=0           - bcm2835 ALSA, bcm2835 ALSA - Direct sample mixing device
#  dmix:CARD=ALSA,DEV=1           - bcm2835 ALSA, bcm2835 IEC958/HDMI - Direct sample mixing device
#  dsnoop:CARD=ALSA,DEV=0         - bcm2835 ALSA, bcm2835 ALSA - Direct sample snooping device
#  dsnoop:CARD=ALSA,DEV=1         - bcm2835 ALSA, bcm2835 IEC958/HDMI - Direct sample snooping device
#  hw:CARD=ALSA,DEV=0             - bcm2835 ALSA, bcm2835 ALSA - Direct hardware device without any conversions
#  hw:CARD=ALSA,DEV=1             - bcm2835 ALSA, bcm2835 IEC958/HDMI - Direct hardware device without any conversions
#  plughw:CARD=ALSA,DEV=0         - bcm2835 ALSA, bcm2835 ALSA - Hardware device with all software conversions
#  plughw:CARD=ALSA,DEV=1         - bcm2835 ALSA, bcm2835 IEC958/HDMI - Hardware device with all software conversions
#


		# Splits the outputs
		# Possibly there is a better solution in Perl with RegEx
		my @outputlist = split(/\n/, $squ_outputs, -1);
		my $line;
		my @outputdevs;
		my @outputdescs;
		foreach $line (@outputlist) {
				if( substr( $line, 0, 2) ne '  ' ) {
					next;
				}
				my @splitoutputs = split(/-/, $line, 2);
				if ((length(trim($splitoutputs[0])) ne 0)) {
						push (@outputdevs, trim($splitoutputs[0]));
						if( $splitoutputs[1] ) {
							push (@outputdescs, trim($splitoutputs[1]));
						} else {
							push (@outputdescs, undef);
						}
				}
		}

		## Generate soundcard list
		my @cards_tmp = `cat /proc/asound/cards`;
		my %cards;
		foreach $line (@cards_tmp) {
			my $bracket_start = index $line, '[';
			my $bracket_finish = index $line, ']';
			if ($bracket_start == -1 or $bracket_finish == -1 or $bracket_finish < $bracket_start) {
				next;
			}
			my $card = trim(substr($line, $bracket_start+1, $bracket_finish-$bracket_start-1));
			print STDERR "CARD: $card\n";
			my @alsacontrols = `amixer -c $card scontrols`;
			# print STDERR "alsacontrols:\n" . join(' ', @alsacontrols) . "\n";
			foreach my $controlline (@alsacontrols) {
				my $tick_start = index $controlline, "'";
				# print "Tickstart: $tick_start\n";
				my $tick_finish = index $controlline, "'", $tick_start+1;
				# print "Tickfinish: $tick_finish\n";
				if ($tick_start == -1 or $tick_finish == -1) {
					next;
				}	
				my $control = trim(substr($controlline, $tick_start+1, $tick_finish-$tick_start-1));
				print STDERR "   CONTROL: $control\n";
				$cards{$card}{$control} = 1;
			}
		}
		
		# Read the Main config file section
		$cfgversion = $cfg->param("Main.ConfigVersion");
		$squ_instances = $cfg->param("Main.Instances");
		$squ_server = $cfg->param("Main.LMSServer");
		$squ_lmswebport = $cfg->param("Main.LMSWebPort");
		$squ_lmscliport = $cfg->param("Main.LMSCLIPort");
		$squ_lmsdataport = $cfg->param("Main.LMSDataPort");
		
		$squ_debug = $cfg->param("Main.debug");
		if (($squ_debug eq "True") || ($squ_debug eq "Yes")) {
			$squ_debug_enabled = 'checked';
		} else {
			$squ_debug_enabled = '';
		}

		$squ_poweroff = $cfg->param("Main.PoweroffPlayers");
		if ($squ_poweroff) {
			$squ_poweroff_enabled = 'checked=checked';
		} else {
			$squ_poweroff_enabled = '';
		}

		$squ_altbinaries = $cfg->param("Main.UseAlternativeBinaries");
		if ($squ_altbinaries) {
			$squ_altbinaries_enabled = 'checked=checked';
		} else {
			$squ_altbinaries_enabled = '';
		}

		# Generate links to LMS and LMS settings $lmslink and $lmssettingslink in topmenu
		if ($squ_server) {
			my $webport = 9000;
			if ($squ_lmswebport) {
				$webport = $squ_lmswebport;
			} 
			$lmslinks = "				<li><a target=\"_blank\" href=\"http://$squ_server:$webport/\">Logitech Media Server</a></li>\n" . 
						"				<li><a target=\"_blank\" href=\"http://$squ_server:$webport/default/settings/index.html\">LMS Settings</a></li>";
		}
		
		# Generate logfile link for navigaton
		$logfileslink = "				<li><a target=\"_blank\" href=\"" . LoxBerry::Web::loglist_url( ) . "\">Logfiles</a></li>\n";
		
		# Read the Instances config file section
		
		for ($instance = 1; $instance <= $squ_instances; $instance++) {
			$enabled = undef;
			$enabled = $cfg->param("Instance" . $instance . ".Enabled");
			push(@inst_enabled, $cfg->param("Instance" . $instance . ".Enabled"));
			push(@inst_name, $cfg->param("Instance" . $instance . ".Name"));
			push(@inst_desc, $cfg->param("Instance" . $instance . ".Description"));
			push(@inst_mac, $cfg->param("Instance" . $instance . ".MAC"));
			LOGINF("Instance$instance output from config: " . join(",", $cfg->param("Instance" . $instance . ".Output")));
			push(@inst_output, join(",", $cfg->param("Instance" . $instance . ".Output")));
			push(@inst_params, join(",", $cfg->param("Instance" . $instance . ".Parameters")));
			push(@inst_alsacontrol, $cfg->param("Instance" . $instance . ".ALSAControl"));
			push(@inst_alsavolume, $cfg->param("Instance" . $instance . ".ALSAVolume"));
			
		}
		
		# If no instances defined yet, show at least one input line
		if ( $squ_instances < 1 ) {
			$squ_instances = 1;
		}
		
		# If first instance has no MAC address, get current system MAC
		if (!defined $inst_mac[0] or length $inst_mac[0] eq 0) {
			$inst_mac[0] = getMAC();
		}
		
		# Generate instance table
	
	for (my $inst = 0; $inst < $squ_instances; $inst++) {
		
		if (($inst_enabled[$inst] eq "True") || ($inst_enabled[$inst] eq "Yes")) {
			$enabled = 'checked';
		} else {
			$enabled = '';
		}
		my $instnr = $inst + 1;
		$htmlout .= '
		<table width="100%" cellpadding="2" cellspacing="0" border="1px" style="background-color: #ffffff;">
		<tr valign="top">
		<th width="5%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_INSTANCE--></p></th>
		<th width="10%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_ACTIVE--></p></th>
		<th width="40%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_INSTANCE_NAME--></p></th>
		<th width="35%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_MAC_ADDRESS--></p></th>
		<th></th>
		</tr>
	
		<tr class="top row">
		<td rowspan="3"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><font size="6">' .
		$instnr . '</font></p>
		</td>
		<td><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="checkbox" name="Enabled' . $instnr . '" value="True" ' . 
		$enabled . '></p>
		</td>
		<td><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" placeholder="<!--$T::INSTANCES_INSTANCE_NAME_HINT-->" name="Name' . $instnr . '" value="' . 
		$inst_name[$inst] . '"></p>
		</td>
		<td><p style="text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" placeholder="<!--$T::INSTANCES_MAC_HINT-->" onkeyup="checkMAC(\'MAC' . $instnr . '\')"w id="MAC' . $instnr . '" name="MAC' . $instnr . '" value="' . 
		$inst_mac[$inst] . '"></p>
		</td>
		<td><a href="JavaScript:setRandomMAC(\'MAC' . $instnr . '\');" id="randommac' . $instnr . '"><img src="/plugins/' . $psubfolder . '/images/dice_30_30.png" alt="<!--$T::INSTANCES_MAC_DICE_HINT-->" title="<!--$T::INSTANCES_MAC_DICE_HINT-->"/></a>
		</td>	
		
		</tr>
		<tr class="bottom row">
		<td><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">';
		if ( ($instnr eq $squ_instances) and ($instnr > 1) ){
			$htmlout .= '<button type="submit" tabindex="-1" form="main_form" name="delbtn" value="del" id="btndel" data-role="button" data-inline="true" data-mini="true" data-iconpos="top" data-icon="delete"><!--$T::BUTTON_DELETE--></button>';
		}
		$htmlout .= '
		</p></td>
		<td><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<select name="Output' . $instnr . '" align="left">
			<option value="' . $inst_output[$inst] . '">' . $inst_output[$inst] . ' <!--$T::INSTANCES_OUTPUT_CURRENT--></option>';
		
		my $outputnr = 0 ;
		foreach $output (@outputdevs) { 
			if($outputdescs[$outputnr] eq "") {
			$htmlout .= "<option value=\"$output\">$output</option>";
			} else {
			$htmlout .= "<option value=\"$output\">$output - $outputdescs[$outputnr]</option>";
			}
			$outputnr += 1;
		}
		$htmlout .= '
		</select>
		</p>
		</td>
		<td><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" placeholder="<!--$T::INSTANCES_ADDITIONAL_PARAMETERS_HINT-->" name="Parameters' . $instnr . '" value="' . $inst_params[$inst] . '"></span></p>
		</td>
		<td></td>
		<input type="hidden" placeholder="<!--$T::INSTANCES_INSTANCE_DESCRIPTION_HINT-->" name="Description' . $instnr . '" value="' . $inst_desc[$inst] . '">
		
		</tr>
		<tr>
		<td><b>Mixer</b></td>
		<td>
			<select name="alsacontrol' . $instnr . '" id="alsacontrol' . $instnr . '">
				<option value="disabled"><!--$T::INSTANCES_ALSA_SELECT_OPTION_HINT--></option>';
				foreach my $card (keys %cards) {
					$htmlout .= "<optgroup label='$card'>\n";
					foreach my $control (keys %{$cards{$card}}) {
						my $sel="";
						if($inst_alsacontrol[$inst] eq "$card|$control") {
							$sel = 'selected="selected"';
						}
						$htmlout .= "<option value='$card|$control' $sel>$control</option>\n";
					}
					$htmlout .= "</optgroup>\n";
				}

		$htmlout .= '
		</select>
		</td>
		<td><input type="text" placeholder="<!--$T::INSTANCES_ALSA_VOLUME_HINT-->" name="alsavolume' . $instnr . '" value="' . $inst_alsavolume[$inst] . '"></span></p></td>
		<td></td>
		</tr>
		
		</table>';
		
	}
	
		if ( !$header_already_sent ) { print "Content-Type: text/html\n\n"; }
		
		#$template_title = $phrase->param("TXT0000") . ": " . $phrase->param("TXT0040");
		$template_title = "Squeezelite Player Plugin";
		
		# Print Header
		&lbheader;
		
		# Print Menu selection
		our $class_player = 'class="ui-btn-active ui-state-persist"';
		
		open(F,"$lbptemplatedir/multi/topmenu.html") || die "Missing template $lbptemplatedir/multi/topmenu.html";
		  while (<F>) 
		  {
		    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    print $_;
		  }
		close(F);
		
		
		# Print Player setting
			
		open(F,"$lbptemplatedir/multi/settings.html") || die "Missing template $lbptemplatedir/multi/settings.html";
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
		
		$cfg_version 	= param('ConfigVersion');
		$squ_server		= trim(param('LMSServer'));
		$squ_instances	= param('Instances');
		$squ_lmswebport = param("LMSWebPort");
		$squ_lmscliport = param("LMSCLIPort");
		$squ_lmsdataport = param("LMSDATAPort");
		$squ_debug		= param('debug');
		$squ_poweroff		= param('poweroff');
		$squ_altbinaries	= param('altbinaries');
		
		if ( $_[0] eq 1) {
			$squ_instances++;
		}
		if ( ( $_[0] eq -1) and ($squ_instances gt 1) ) {
			$cfg->delete("Instance$squ_instances");
			$squ_instances--;
		}
		
		$cfg->param("Main.ConfigVersion", $cfg_version);
		$cfg->param("Main.LMSServer", $squ_server);
		$cfg->param("Main.LMSWebPort", $squ_lmswebport);
		$cfg->param("Main.LMSCLIPort", $squ_lmscliport);
		$cfg->param("Main.LMSDataPort", $squ_lmsdataport);
		$cfg->param("Main.Instances", $squ_instances);
		if ($squ_debug) {
			$cfg->param("Main.debug", "Yes");
		} else {
			$cfg->param("Main.debug", "False");
		}
		if ($squ_poweroff) {
			$cfg->param("Main.PoweroffPlayers", "1");
		} else {
			$cfg->param("Main.PoweroffPlayers", "0");
		}
		if ($squ_altbinaries) {
			$cfg->param("Main.UseAlternativeBinaries", "1");
		} else {
			$cfg->param("Main.UseAlternativeBinaries", "0");
		}
		
		# Run through instance table
		
		for ($instance = 1; $instance <= $squ_instances; $instance++) {
			my $enabled = param("Enabled$instance");
			my $name = trim(param("Name$instance"));
			my $MAC = lc trim(param("MAC$instance"));
			
			my $output = param("Output$instance");
			my $params = trim(param("Parameters$instance"));
			my $desc = trim(param("Descriptiom$instance"));
			my $alsacontrol = param("alsacontrol$instance");
			my $alsavolume = param("alsavolume$instance");
			# Possible validations here
			
			# Write to config

			$cfg->param("Instance$instance.Enabled", $enabled);
			$cfg->param("Instance$instance.Name", $name);
			$cfg->param("Instance$instance.MAC", $MAC);
			LOGDEB("Instance$instance output from form: " . $output);
			$cfg->param("Instance$instance.Output", $output);
			$cfg->param("Instance$instance.Parameters", $params);
			$cfg->param("Instance$instance.Description", $desc);
			$cfg->param("Instance$instance.ALSAControl", $alsacontrol);
			$cfg->param("Instance$instance.ALSAVolume", $alsavolume);
			
			
			
			
		}
		$cfg->save();
	}

	
	
	
#####################################################
# Apply-Sub
#####################################################
	
	sub restartSqueezelite	
	{
		
		my $killscript = "sudo $lbpbindir/kill_squeezelite.sh";
		system($killscript);
		
		my $startscript = "$lbpbindir/start_instances.cgi > /dev/null";
		system($startscript);
	
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
	
	$languagefileplugin	= "$lbptemplatedir/lang/help_en.ini";
	$plglang = new Config::Simple($languagefileplugin);
	$plglang->import_names('T');

	# Read foreign language if exists and not English
	$languagefileplugin = "$lbptemplatedir/lang/help_$lang.ini";
	 if ((-e $languagefileplugin) and ($lang ne 'en')) {
		# Now overwrite phrase variables with user language
		$plglang = new Config::Simple($languagefileplugin);
		$plglang->import_names('T');
	}
	  
	# Parse help template
	open(F,"$lbptemplatedir/multi/help.html") || die "Missing template $lbptemplatedir/multi/help.html";
		while (<F>) {
			$_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    $helptext = $helptext . $_;
		}
	close(F);
	open(F,"$lbstemplatedir/$lang/header.html") || die "Missing template $lbstemplatedir/$lang/header.html";
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
	  open(F,"$lbstemplatedir/$lang/footer.html") || die "Missing template $lbstemplatedir/$lang/footer.html";
	    while (<F>) 
	    {
	      $_ =~ s/<!--\$(.*?)-->/${$1}/g;
	      print $_;
	    }
	  close(F);
	}


# #####################################################
# # Strings trimmen
# #####################################################

# sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

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
# Get path of Squeezelite binary
#####################################################

sub sl_path {
	# Normal or alternative binaries
	my $sl_path;

	if (! $cfg->param("Main.UseAlternativeBinaries") ) {
		# Use original Debian binary
		LOGOK("Using original Debian Squeezelite binary");
		$sl_path = 'squeezelite';
	} else {
		# Use alternative binaries
		
		# Check architecture
		my $archstring = `/bin/uname -a`;
		LOGDEB("uname -a: $archstring");
		if ( index($archstring, 'armv') != -1 ) {
			LOGOK("Using ARM Squeezelite binary");
			$sl_path = "$lbpdatadir/squeezelite-armv6hf";
		} elsif ( index($archstring, 'x86_64') != -1 ) {
			LOGOK("Using x64 Squeezelite binary");
			$sl_path = "$lbpdatadir/squeezelite-x64";
		} elsif ( index($archstring, 'x86') != -1 ) {
			LOGOK("Using x86 Squeezelite binary");
			$sl_path = "$lbpdatadir/squeezelite-x86";
		} else {
			LOGERR("Could not determine architecture - falling back to original Debian Squeezelite binary");
			$sl_path = 'squeezelite';
		}
	}
	return $sl_path;

}

END
{
	if($log) {
		LOGEND "index.cgi completed";
	}
}
