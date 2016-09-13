#!/usr/bin/perl

# This script is called by the DAEMON bash script 
# to collect Squeezelite config and return a 
# startable commandline (or multiple for multiple instances)

use File::HomeDir;
use Config::Simple;
use warnings;
use strict;
no strict "refs"; # we need it for template system

my  $home = File::HomeDir->my_home;
my  $lang;
my  $installfolder;
my  $cfg;
our $helptext;
our $template_title;
our $pluginname;
my $cfgversion=0;
my $squ_instances=0;
my $aqu_server;
my @inst_enabled;
my @inst_name;
my @inst_desc;
my @inst_mac;
my @inst_output;
my @inst_params;
my @commandline;

$pluginname = abs_path($0);
$pluginname =~ s/(.*)\/(.*)\/(.*)$/$2/g;

# Read global settings
$cfg             = new Config::Simple("$home/config/system/general.cfg");
$installfolder   = $cfg->param("BASE.INSTALLFOLDER");
$lang            = $cfg->param("BASE.LANG");

# Read plugin settings
$cfg = new Config::Simple("$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg") or die Config::Simple->error();

# Read the Main section
$cfgversion = $cfg->param("Main.ConfigVersion");
$squ_instances = $cfg->param("Main.Instances");
$squ_server = $cfg->param("Main.LMSServer");

# Read the Instances section
for ($instance = 1; $instance <= $squ_instances; $instance++) {
	$enabled = NULL;
	$enabled = $cfg->param("Instance" . $instance . ".Enabled");
	if (($enabled eq "True") || ($enabled eq "Yes")) {
		push(@inst_enabled, $cfg->param("Instance" . $instance . ".Enabled"));
		push(@inst_name, $cfg->param("Instance" . $instance . ".Name"));
		push(@inst_desc, $cfg->param("Instance" . $instance . ".Description"));
		push(@inst_mac, $cfg->param("Instance" . $instance . ".MAC"));
		push(@inst_output, $cfg->param("Instance" . $instance . ".Output"));
		push(@inst_params, $cfg->param("Instance" . $instance . ".Parameters"));
	# ToDo: At some point, we may validate the config file parameters, and define dependencies of options.
	}
}

# Create the command line
$instcount = scalar @inst_name;
for ($instance = 0; $instance < $instcount; $instance++) {
	$command = 	"squeezelite" . 
				" -s " . $squ_server .
				" -o " . @inst_output[$instance] . 
				" -m " . @inst_mac[$instance] . 
				" -n " . @inst_name[$instance] . 
				" -z " .
				" -f $installfolder/log/plugins/$pluginname/squeezelite_" . ($instance+1) . ".log";
	# Starten
	system($command);
}

exit;
