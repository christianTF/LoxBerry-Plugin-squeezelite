#!/usr/bin/perl

# This script is called by the DAEMON bash script 
# to collect Squeezelite config and return a 
# startable commandline (or multiple for multiple instances)

use LoxBerry::System;
use LoxBerry::Log;

use POSIX 'strftime';
use File::HomeDir;
use Config::Simple;
use warnings;
use Scalar::Util qw(looks_like_number);
use strict;
no strict "refs"; # we need it for template system
use Cwd 'abs_path';
# use Tie::LogFile;

# Version of this script
our $version = "1.0.1.2";

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
our $squ_altbinaries;

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

# Init logfile
my $log = LoxBerry::Log->new (
    name => 'Start_Instances',
	addtime => 1,
	loglevel => 7,
);

LOGSTART "Starting Squeezelite instances";

$home = $lbhomedir;
$pluginname = $lbpplugindir;

# Read global settings
 #$cfg             = new Config::Simple("$home/config/system/general.cfg") or LOGCRIT("Cannot open Loxberry general config file, exiting - $!");
 $installfolder = $lbhomedir;
 $lang            = LoxBerry::System::lblanguage();

# Read plugin settings
LOGINF("Reading Plugin configuration");
$cfg = new Config::Simple("$lbpconfigdir/plugin_squeezelite.cfg") or LOGCRIT ("Cannot open config file: $!");
# if (not defined($cfg)) {
	# tolog ("WARNING", "No Loxberry-Plugin-$pluginname configuration found - Exiting.\n");
	# exit(1);
# }

# Read the Main section
$cfgversion = $cfg->param("Main.ConfigVersion");
$squ_instances = $cfg->param("Main.Instances");
$squ_server = $cfg->param("Main.LMSServer");
$squ_lmswebport = $cfg->param("Main.LMSWebPort");
$squ_lmscliport = $cfg->param("Main.LMSCLIPort");
$squ_lmsdataport = $cfg->param("Main.LMSDataPort");
$squ_altbinaries = $cfg->param("Main.UseAlternativeBinaries");
		
LOGINF ("Check if instances are defined in config file");
LOGINF ("Number of instances: $squ_instances");
if ( $squ_instances < 1 ) {
	LOGOK ("No instances defined in config file. Exiting.");
	exit;
	}

# Read the Instances section
for ($instance = 1; $instance <= $squ_instances; $instance++) {
	LOGINF ("Parsing instance $instance configuration");
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
LOGINF ("Creating the command lines for squeezelite");
$instcount = scalar @inst_name;

my $server_and_port;
if ($squ_server ne "") {
	$server_and_port = $squ_server;
	if ($squ_lmsdataport ne "") {
		$server_and_port .= ":$squ_lmsdataport";
	}
}

# Normal or alternative binaries
my $sl_path;

if (! $squ_altbinaries) {
	# Use original Debian binary
	LOGOK("Using original Debian Squeezelite binary");
	$sl_path = 'squeezelite';
} else {
	# Use alternative binaries
	
	# Check architecture
	my $archstring = `/bin/uname -a`;
	if ( index($archstring, 'armv') != -1 ) {
		LOGOK("Using ARM Squeezelite binary");
		$sl_path = "$lbpdatadir/squeezelite-armv6hf";
	} elsif ( index($archstring, 'x86_64') != -1 ) { 
		LOGOK ("Using x64 Squeezelite binary");
		$sl_path = "$lbpdatadir/squeezelite-x64";
	} elsif ( index($archstring, 'x86') != -1 ) { 
		LOGOK ("Using x86 Squeezelite binary");
		$sl_path = "$lbpdatadir/squeezelite-x86";
	} else {
		LOGERR ("Could not determine architecture - falling back to original Debian Squeezelite binary");
		$sl_path = 'squeezelite';
	}
}

for ($instance = 0; $instance < $instcount; $instance++) {
	$command = $sl_path;
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
	
	#$command .= " -f $lbplogdir/squeezelite_" . ($instance+1) . ".log > /dev/null &";
	$command .= " -f " . $log->filename . " > /dev/null &";
	
	# Starten
	LOGINF("Starting instance $instance with command:");
	LOGINF("$command");
	my $output = `$command`;
	LOGINF ("Errors of the Squeezelite instances are appended to the end of the log.");
}

LOGOK ("Finished to start all instances");
exit;

END
{
	if($log) {
		LOGEND "Start Instances finished";
	}
}