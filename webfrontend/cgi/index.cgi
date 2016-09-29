#!/usr/bin/perl

# Copyright 2016 Christian Fenzl, christiantf@gmx.at
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

our $cfg;
our $phrase;
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
our $version;
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

our $pluginname;

our $cfgfilename;
our $cfgversion=0;
our $cfg_version;
our $squ_instances=0;
our $squ_server;
our $squ_debug;
our $lmslink;
our $lmssettingslink;
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

my $logname;
my $loghandle;
my $logmessage;


##########################################################################
# Read Settings
##########################################################################

# Version of this script
$version = "0.1.1";

# Figure out in which subfolder we are installed
$pluginname = abs_path($0);
$pluginname =~ s/(.*)\/(.*)\/(.*)$/$2/g;

# Read global settings

$cfg             = new Config::Simple("$home/config/system/general.cfg");
$installfolder   = $cfg->param("BASE.INSTALLFOLDER");
$lang            = $cfg->param("BASE.LANG");

# Initialize logfile
if ($debug) {
	$logname = "$installfolder/log/plugins/$pluginname/index.log";
	open ($loghandle, '>>' , $logname); # or warn "Cannot open logfile for writing (Permission?) - Continuing without log\n";
	chmod (0666, $loghandle); # or warn "Cannot change logfile permissions\n";	
}


# Read plugin settings
tolog("INFORMATION", "Reading Plugin config $cfgfilename");
$cfgfilename = "$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg";
if (-e $cfgfilename) {
	tolog("INFORMATION", "Plugin config existing - loading");
	$cfg = new Config::Simple($cfgfilename);
}
unless (-e $cfgfilename) {
	tolog("INFORMATION", "Plugin config NOT existing - creating");
	$cfg = new Config::Simple(syntax=>'ini');
	$cfg->param("Main.ConfigVersion", 1);
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
# Don't know why this is so complicated...
	if ( !$query{'saveformdata'} ) { if ( param('saveformdata') ) { $saveformdata = quotemeta(param('saveformdata')); } else { $saveformdata = 0;      } } else { $saveformdata = quotemeta($query{'saveformdata'}); }
	if ( !$query{'lang'} )         { if ( param('lang')         ) { $lang         = quotemeta(param('lang'));         } else { $lang         = "de";   } } else { $lang         = quotemeta($query{'lang'});         }
#	if ( !$query{'do'} )           { if ( param('do')           ) { $do           = quotemeta(param('do'));           } else { $do           = "form"; } } else { $do           = quotemeta($query{'do'});           }

	if 	( param('applybtn') ) 	{ $doapply = 1; }
	elsif ( param('addbtn') ) 	{ $doadd = 1; }
	elsif ( param('delbtn') )	{ $dodel = 1; }
	
	
# Clean up saveformdata variable
	$saveformdata =~ tr/0-1//cd; $saveformdata = substr($saveformdata,0,1);

# Init Language
	# Clean up lang variable
	$lang         =~ tr/a-z//cd; $lang         = substr($lang,0,2);
# If there's no language phrases file for choosed language, use german as default
	if (!-e "$installfolder/templates/system/$lang/language.dat") 
	{
  		$lang = "de";
	}
# Read LoxBerry system translations / phrases
	$languagefile 			= "$installfolder/templates/system/$lang/language.dat";
	$phrase 				= new Config::Simple($languagefile);
	
# Read Plugin transations
# Read English language as default
# Missing phrases in foreign language will fall back to English	
	
	$languagefileplugin 	= "$installfolder/templates/plugins/$pluginname/en/language.txt";
	$plglang = new Config::Simple($languagefileplugin);
	$plglang->import_names('T');

#	$lang = 'en'; # DEBUG
	
# Read foreign language if exists and not English
	$languagefileplugin = "$installfolder/templates/plugins/$pluginname/$lang/language.txt";
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
		if ($doapply) 		{ 	tolog("DEBUG", "doapply triggered - save, restart, refresh form");
									&save;
									&restartSqueezelite; }
		elsif ($doadd)	{ 	tolog("DEBUG", "doaadd triggered - save with +1, refresh form");
							&save(1); }
		elsif ($dodel)	{ 	tolog("DEBUG", "doadel triggered - save with -1, refresh form");
							&save(-1); }
		else { 				tolog("DEBUG", "save triggered - save, refresh form");
							&save; }
	  &form;
	}
	else 
	{
	  tolog("DEBUG", "form triggered - load form");
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
		# $debug     = quotemeta($debug);
		tolog("INFORMATION", "save triggered - save, refresh form");
							
		# Prepare form defaults
		# Read Squeezelite possible sound outputs
		tolog("INFORMATION", "Calling squeezelite to get outputs");
		my $squ_outputs = `sudo squeezelite -l` or tolog("ERROR", "Failed to run squeezelite.");
		
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
				my @splitoutputs = split(/-/, $line, 2);
				if ((length(trim($splitoutputs[0])) ne 0) && (defined $splitoutputs[1])) {
						push (@outputdevs, trim($splitoutputs[0]));
						push (@outputdescs, trim($splitoutputs[1]));
				}
		}

		# Read the Main config file section
		$cfgversion = $cfg->param("Main.ConfigVersion");
		$squ_instances = $cfg->param("Main.Instances");
		$squ_server = $cfg->param("Main.LMSServer");
		$squ_debug = $cfg->param("Main.debug");
		if (($squ_debug eq "True") || ($squ_debug eq "Yes")) {
			$squ_debug_enabled = 'checked';
			# $debug = 1;
		} else {
			$squ_debug_enabled = '';
			# $debug = 0;
		}

		# Generate links to LMS and LMS settings $lmslink and $lmssettingslink
		if ($squ_server) {
			my @splitlms = split(/:/, $squ_server);
			$lmslink 			= "<a target=\"_blank\" href=\"http://@splitlms[0]:9000/\">Logitech Media Server</a>";
			$lmssettingslink 	= "<a target=\"_blank\" href=\"http://@splitlms[0]:9000/settings/index.html\">LMS Settings</a>";
			
		}
		
		
		# Read the Instances config file section
		for ($instance = 1; $instance <= $squ_instances; $instance++) {
			$enabled = undef;
			$enabled = $cfg->param("Instance" . $instance . ".Enabled");
			push(@inst_enabled, $cfg->param("Instance" . $instance . ".Enabled"));
			push(@inst_name, $cfg->param("Instance" . $instance . ".Name"));
			push(@inst_desc, $cfg->param("Instance" . $instance . ".Description"));
			push(@inst_mac, $cfg->param("Instance" . $instance . ".MAC"));
			tolog("DEBUG", "Instance$instance output from config: " . join(",", $cfg->param("Instance" . $instance . ".Output")));
			push(@inst_output, join(",", $cfg->param("Instance" . $instance . ".Output")));
			push(@inst_params, join(",", $cfg->param("Instance" . $instance . ".Parameters")));
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
		<table width="100%" cellpadding="2" cellspacing="0" border="1px">
		<tr valign="top">
		<th width="5%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_INSTANCE--></p></th>
		<th width="5%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_ACTIVE--></p></th>
		<th width="40%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_INSTANCE_NAME--></p></th>
		<th width="47%"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><!--$T::INSTANCES_TABLE_HEAD_MAC_ADDRESS--></p></th>
		<th width="3%"></th>
		</tr>
	
		<tr class="top row">
		<td rowspan="2"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><font size="6">' .
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
		<td><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" placeholder="<!--$T::INSTANCES_MAC_HINT-->" onkeyup="checkMAC(\'MAC' . $instnr . '\')"w id="MAC' . $instnr . '" name="MAC' . $instnr . '" value="' . 
		$inst_mac[$inst] . '"></p>
		</td>
		<td><a href="JavaScript:setRandomMAC(\'MAC' . $instnr . '\');" id="randommac' . $instnr . '"><img src="/plugins/' . $pluginname . '/images/dice_30_30.png" alt="<!--$T::INSTANCES_MAC_DICE_HINT-->" title="<!--$T::INSTANCES_MAC_DICE_HINT-->"/></a>
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
			$htmlout .= "<option value=\"$output\">$output - $outputdescs[$outputnr]</option>";
			$outputnr += 1;
		}
		$htmlout .= '
		</select>
		</p>
		</td>
		<td><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" placeholder="<!--$T::INSTANCES_ADDITIONAL_PARAMETERS_HINT-->" name="Parameters' . $instnr . '" value="' . $inst_params[$inst] . '"></span></p>
		</td>
		<td>
		</td>
		<input type="hidden" placeholder="<!--$T::INSTANCES_INSTANCE_DESCRIPTION_HINT-->" name="Description' . $instnr . '" value="' . $inst_desc[$inst] . '">
		</tr>
		</table>';
		
	}
	
		if ( !$header_already_sent ) { print "Content-Type: text/html\n\n"; }
		
		#$template_title = $phrase->param("TXT0000") . ": " . $phrase->param("TXT0040");
		$template_title = "Squeezelite Player Plugin";
		
		# Get number of running Squeezelite processes
		$runningInstances = `pgrep --exact -c squeezelite`;
		
		# Print Template
		&lbheader;
		open(F,"$installfolder/templates/plugins/$pluginname/multi/settings.html") || die "Missing template plugins/$pluginname/multi/settings.html";
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
		$squ_debug		= param('debug');
		
		if ( $_[0] eq 1) {
			$squ_instances++;
		}
		if ( ( $_[0] eq -1) and ($squ_instances gt 1) ) {
			$cfg->delete("Instance$squ_instances");
			$squ_instances--;
		}
		
		
		$cfg->param("Main.ConfigVersion", $cfg_version);
		$cfg->param("Main.LMSServer", $squ_server);
		$cfg->param("Main.Instances", $squ_instances);
		if ($squ_debug) {
			$cfg->param("Main.debug", "Yes");
		} else {
			$cfg->param("Main.debug", "False");
		}
		
		
		# Run through instance table
		
		for ($instance = 1; $instance <= $squ_instances; $instance++) {
			my $enabled = param("Enabled$instance");
			my $name = trim(param("Name$instance"));
			my $MAC = lc trim(param("MAC$instance"));
			
			my $output = param("Output$instance");
			my $params = trim(param("Parameters$instance"));
			my $desc = trim(param("Descriptiom$instance"));

			# Possible validations here
			
			# Write to config

			$cfg->param("Instance$instance.Enabled", $enabled);
			$cfg->param("Instance$instance.Name", $name);
			$cfg->param("Instance$instance.MAC", $MAC);
			tolog("DEBUG", "Instance$instance output from form: " . $output);
			$cfg->param("Instance$instance.Output", $output);
			$cfg->param("Instance$instance.Parameters", $params);
			$cfg->param("Instance$instance.Description", $desc);
			
		}
		$cfg->save();
		
		# if ( !$header_already_sent ) { print "Content-Type: text/html\n\n"; }
		
		#$template_title = $phrase->param("TXT0000") . ": " . $phrase->param("TXT0040");
		#$message 				= $phraseplugin->param("TXT0002");
		#$nexturl 				= "./index.cgi?do=form";
		
		# Print Template
		# &lbheader;
		# open(F,"$installfolder/templates/system/$lang/success.html") || die "Missing template system/$lang/succses.html";
		  # while (<F>) 
		  # {
		    # $_ =~ s/<!--\$(.*?)-->/${$1}/g;
		    # print $_;
		  # }
		# close(F);
		# &footer;
		# exit;
	}

	
	
	
#####################################################
# Apply-Sub
#####################################################
	
	sub restartSqueezelite	
	{
		
		my $killscript = "sudo /opt/loxberry/data/plugins/$pluginname/kill_squeezelite.sh";
		system($killscript);
		
		my $startscript = "sudo $installfolder/webfrontend/cgi/plugins/squeezelite/start_instances.cgi > /dev/null";
		system($startscript);
	
	}
	
	
#####################################################
# Error-Sub
#####################################################

	sub error 
	{
		$template_title = $phrase->param("TXT0000") . " - " . $phrase->param("TXT0028");
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
	  open(F,"$installfolder/templates/plugins/$pluginname/$lang/help.html") || die "Missing template plugins/$pluginname/$lang/help.html";
	    @help = <F>;
	    foreach (@help)
	    {
	      s/[\n\r]/ /g;
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
# Strings trimmen
#####################################################

sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

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

  undef $s, @interfaces;
  return $mac;
}

#####################################################
# Logging
#####################################################

sub tolog {
  print strftime("%Y-%m-%d %H:%M:%S", localtime(time)) . " $_[0]: $_[1]\n";
  if ($debug) {
	if ($loghandle) {
		print $loghandle strftime("%Y-%m-%d %H:%M:%S", localtime(time)) . " $_[0]: $_[1]\n";
	}
  }
}
