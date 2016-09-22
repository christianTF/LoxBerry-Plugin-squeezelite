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

use CGI::Carp qw(fatalsToBrowser);
use CGI qw/:standard/;
use Config::Simple;
use File::HomeDir;
use Cwd 'abs_path';
use Net::Address::Ethernet qw( get_address );
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
my  $home = File::HomeDir->my_home;
our $pname;
our $debug=1;
our $languagefileplugin;
our $phraseplugin;
our $selectedverbose;
our $selecteddebug;
our $header_already_sent=0;

our $pluginname;

our $cfgversion=0;
our $cfg_version;
our $squ_instances=0;
our $squ_server;
our $instance;
our $enabled;
our @inst_enabled;
our @inst_name;
our @inst_desc;
our @inst_mac;
our @inst_output;
our @inst_params;
our @commandline;
our $htmlout;


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


# Read plugin settings
$cfg = new Config::Simple("$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg");


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

	if ( param('applybtn') ) {
		$doapply = 1;
	}
	
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
	# Read translations / phrases
		$languagefile 			= "$installfolder/templates/system/$lang/language.dat";
		$phrase 						= new Config::Simple($languagefile);
		$languagefileplugin = "$installfolder/templates/plugins/$pluginname/$lang/language.dat";
		$phraseplugin 			= new Config::Simple($languagefileplugin);

##########################################################################
# Main program
##########################################################################

	if ($saveformdata) 
	{
		&save;
		if ($doapply) {
			&restartSqueezelite;
			
		}
	  &form;
	}
	else 
	{
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
		$debug     = quotemeta($debug);
		
		# Prepare form defaults
		# Read Squeezelite possible sound outputs
		
		my $squ_outputs = `squeezelite -l`;
		
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

		# Read the Instances config file section
		for ($instance = 1; $instance <= $squ_instances; $instance++) {
			$enabled = undef;
			$enabled = $cfg->param("Instance" . $instance . ".Enabled");
			push(@inst_enabled, $cfg->param("Instance" . $instance . ".Enabled"));
			push(@inst_name, $cfg->param("Instance" . $instance . ".Name"));
			push(@inst_desc, $cfg->param("Instance" . $instance . ".Description"));
			push(@inst_mac, $cfg->param("Instance" . $instance . ".MAC"));
			push(@inst_output, $cfg->param("Instance" . $instance . ".Output"));
			push(@inst_params, $cfg->param("Instance" . $instance . ".Parameters"));
		}

		
		# If no instances defined yet, show at least one input line
		if ( $squ_instances < 1 ) {
			$squ_instances = 1;
		}
		
		# If first instance has no MAC address, get current system MAC
		if (!defined $inst_mac[0] or length $inst_mac[0] eq 0) {
			$inst_mac[0] = get_address;
		}
		
		# Generate instance table
	
	for (my $inst = 0; $inst < $squ_instances; $inst++) {
		
		if (($inst_enabled[$inst] eq "True") || ($inst_enabled[$inst] eq "Yes")) {
			$enabled = 'checked';
		} else {
			$enabled = '';
		}
		my $instnr = $inst + 1;
		$htmlout = '
		<tr>
		<td style="border-width : 0px;"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;"><font size="6">' .
		$instnr . '</font></p>
		</td>
		<td style="border-width : 0px;"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="checkbox" name="Enabled' . $instnr . '" value="True" ' . 
		$enabled . '></p>
		</td>
		<td style="border-width : 0px;"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" name="Name' . $instnr . '" value="' . 
		$inst_name[$inst] . '"></p>
		</td>
		<td style="border-width : 0px;"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" name="MAC' . $instnr . '" value="' . 
		$inst_mac[$inst] . '"></p>
		</td>
		<td style="border-width : 0px;"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<select name="Output' . $instnr . '" align="left">
			<option value="' . $inst_output[$inst] . '">' . $inst_output[$inst] . ' (aktuell) </option>';
		
		my $outputnr = 0 ;
		foreach $output (@outputdevs) { 
			$htmlout .= "<option value=\"$output\">$output - $outputdescs[$outputnr]</option>";
			$outputnr += 1;
		}
		$htmlout .= '
		</select>
		</p>
		</td>
		<td style="border-width : 0px;"><p style=" text-align: left; text-indent: 0px; padding: 0px 0px 0px 0px; margin: 0px 0px 0px 0px;">
		<input type="text" name="Parameters' . $instnr . '" value="' . $inst_params[$inst] . '"></span></p>
		</td>
		<input type="hidden" name="Description' . $instnr . '" value="' . $inst_desc[$inst] . '">
		</tr>';
		
	}
			
		if ( !$header_already_sent ) { print "Content-Type: text/html\n\n"; }
		
		#$template_title = $phrase->param("TXT0000") . ": " . $phrase->param("TXT0040");
		$template_title = "Squeezelite Plugin";
		
		# Print Template
		&lbheader;
		open(F,"$installfolder/templates/plugins/$pluginname/$lang/settings.html") || die "Missing template plugins/$pluginname/$lang/settings.html";
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
# Save-Sub
#####################################################

	sub save 
	{
		
		# Read global plugin values from form and write to config
		
		$cfg_version 	= param('ConfigVersion');
		$squ_server		= param('LMSServer');
		$squ_instances	= param('Instances');
		
		
		$cfg->param("Main.ConfigVersion", $cfg_version);
		$cfg->param("Main.LMSServer", $squ_server);
		$cfg->param("Main.Instances", $squ_instances);
		
		
		# Run through instance table
		
		for ($instance = 1; $instance <= $squ_instances; $instance++) {
			my $enabled = param("Enabled$instance");
			my $name = param("Name$instance");
			my $MAC = param("MAC$instance");
			my $output = param("Output$instance");
			my $params = param("Parameters$instance");
			my $desc = param("Descriptiom$instance");

			# Possible validations here
			
			# Write to config

			$cfg->param("Instance$instance.Enabled", $enabled);
			$cfg->param("Instance$instance.Name", $name);
			$cfg->param("Instance$instance.MAC", $MAC);
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
		
		# For any reason, this call does not come back and browser is awaiting response.
		my $startscript = "$installfolder/webfrontend/cgi/plugins/squeezelite/start_instances.cgi";
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
	  $helplink = "http://www.loxwiki.eu:80/display/LOXBERRY/Miniserverbackup";
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
