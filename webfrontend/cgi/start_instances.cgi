#!/usr/bin/perl

# This script is called by the DAEMON bash script 
# to collect Squeezelite config and return a 
# startable commandline (or multiple for multiple instances)

use POSIX 'strftime';
use File::HomeDir;
use Config::Simple;
use warnings;
use strict;
no strict "refs"; # we need it for template system
use Cwd 'abs_path';
# use Tie::LogFile;

my  $home; 
my  $lang;
my  $installfolder;
my  $cfg;
our $debug=1;
our $helptext;
our $template_title;
our $pluginname;

my $logname;
my $loghandle;
my $logmessage;

my $cfgversion=0;
my $squ_instances=0;
my $squ_server;
our $squ_lmswebport;
our $squ_lmscliport;
our $squ_lmsdataport;


my $instance;
my $enabled;
my $instcount;
my $command;

my @inst_enabled;
my @inst_name;
my @inst_desc;
my @inst_mac;
my @inst_output;
my @inst_params;
my @commandline;

$home = "REPLACEINSTALLFOLDER";

# Directory/Pluginname fallback for test environment
unless (-d $home) { 
	$home = "/opt/loxberry";
}

$pluginname = abs_path($0);
$pluginname =~ s/(.*)\/(.*)\/(.*)$/$2/g;

# Read global settings
 $cfg             = new Config::Simple("$home/config/system/general.cfg") or tolog("ERROR", "Cannot open Loxberry general config file, exiting - $!");
 $installfolder   = $cfg->param("BASE.INSTALLFOLDER");
 $lang            = $cfg->param("BASE.LANG");

# Initialize logfile
if ($debug) {
	$logname = "$installfolder/log/plugins/$pluginname/start_instances.log";
	open ($loghandle, '>>' , $logname); # or warn "Cannot open logfile for writing (Permission?) - Continuing without log\n";
	chmod (0666, $loghandle); # or warn "Cannot change logfile permissions\n";	
}
# Read plugin settings
tolog("INFORMATION", "Reading Plugin config");
$cfg = new Config::Simple("$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg") or tolog("ERROR", "Cannot open config file: $!\n");
if (not defined($cfg)) {
	tolog ("WARNING", "No Loxberry-Plugin-$pluginname configuration found - Exiting.\n");
	exit(1);
}

# Read the Main section
$cfgversion = $cfg->param("Main.ConfigVersion");
$squ_instances = $cfg->param("Main.Instances");
$squ_server = $cfg->param("Main.LMSServer");
$squ_lmswebport = $cfg->param("Main.LMSWebPort");
$squ_lmscliport = $cfg->param("Main.LMSCLIPort");
$squ_lmsdataport = $cfg->param("Main.LMSDataPort");
		
tolog("INFORMATION", "Check if instances are defined in config file");
tolog("DEBUG", "Number of instances: $squ_instances");
if ( $squ_instances < 1 ) {
	tolog("WARNING", "No instances defined in config file. Exiting.\n");
	exit;
	}

# Read the Instances section
for ($instance = 1; $instance <= $squ_instances; $instance++) {
	tolog("INFORMATION", "Parsing instance $instance configuration");
	$enabled = undef;
	$enabled = $cfg->param("Instance" . $instance . ".Enabled");
	if (($enabled eq "True") || ($enabled eq "Yes")) {
		push(@inst_enabled, $cfg->param("Instance" . $instance . ".Enabled"));
		push(@inst_name, $cfg->param("Instance" . $instance . ".Name"));
		push(@inst_desc, $cfg->param("Instance" . $instance . ".Description"));
		push(@inst_mac, $cfg->param("Instance" . $instance . ".MAC"));
		push(@inst_output, join(",", $cfg->param("Instance" . $instance . ".Output")));
		push(@inst_params, join(",", $cfg->param("Instance" . $instance . ".Parameters")));
	# ToDo: At some point, we may validate the config file parameters, and define dependencies of options.
	}
}

# Create the command line
tolog("INFORMATION", "Creating the command lines for squeezelite");
$instcount = scalar @inst_name;

my $server_and_port;
if ($squ_server ne "") {
	$server_and_port = $squ_server;
	if ($squ_lmsdataport ne "") {
		$server_and_port .= ":$squ_lmsdataport";
	}
}

for ($instance = 0; $instance < $instcount; $instance++) {
	$command = 	"$installfolder/data/plugins/$pluginname/squeezelite";
	# Wird in den Parametern kein -a gefunden, senden wir per Default -a 80 (ALSA-Buffer)
	if (index($inst_params[$instance], "-a ") == -1) {
		$command .= " -a 160";
	}
	if ($server_and_port ne "") {
		$command .= " -s $server_and_port";
	}
	if ($inst_output[$instance] ne "") {
		$command .= " -o $inst_output[$instance]";
	}
	if ($inst_mac[$instance] ne "") {
		$command .= " -m $inst_mac[$instance]";
	}
	if ($inst_name[$instance] ne "") {
		$command .= " -n \\\"$inst_name[$instance]\\\"";
	}
	if ($inst_params[$instance] ne "") {
		$command .= " " . $inst_params[$instance];
	}
	$command .= " -f $installfolder/log/plugins/$pluginname/squeezelite_" . ($instance+1) . ".log > /dev/null &";
	
	# Starten
	tolog("DEBUG", "Starting instance $instance with: $command");
	system("su -c \"$command\" squeezelox > /dev/null");
	tolog("DEBUG", "Starting instance $instance returned");
}

tolog("INFORMATION", "Finished - Closing log and exiting.");
if ($loghandle) {
	close($loghandle) or die "Couldn't close logfile $logname\n";
}
exit;

sub tolog {
  # print strftime("%Y-%m-%d %H:%M:%S", localtime(time)) . " $_[0]: $_[1]\n";
  if ($debug) {
	if ($loghandle) {
		print $loghandle strftime("%Y-%m-%d %H:%M:%S", localtime(time)) . " $_[0]: $_[1]\n";
	}
  }
}
