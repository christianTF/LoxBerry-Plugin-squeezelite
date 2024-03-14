#!/usr/bin/perl
#use LoxBerry::IO;
#use LoxBerry::Log;
use LoxBerry::System;
use CGI;
use Config::Simple;
use JSON;
use warnings;
use strict;

#require "$lbpbindir/libs/Net/MQTT/Simple.pm";
#require "$lbpbindir/libs/LoxBerry/JSON/JSONIO.pm";

my $json;
my $cfg;
my $error;
my $req;
my %response;

my $cgi = CGI->new;

# Check input

# Read plugin settings
my $cfgfilename = "$lbpconfigdir/plugin_squeezelite.cfg";
#LOGINF("Reading Plugin config $cfgfilename");
if (-e $cfgfilename) {
	#LOGOK("Plugin config existing - loading");
	$cfg = new Config::Simple($cfgfilename);
}
unless (-e $cfgfilename) {
	#LOGOK("Plugin config NOT existing - creating");
	$response{'instances'} = 'No config file';
	$response{'instancecount'} = 0;
	$response{'lms2udp'} = 'No config file';
	$response{'lms2udpcount'} = 0;
	$response{'error'} = 'No config file';
	print_response();
}

# LMS2UDP
if (is_enabled($cfg->param('LMS2UDP.activated'))) {
	$response{'lms2udpcount'} = trim(`pgrep -c lms2udp.pl`);
} else {
	$response{'lms2udpcount'} = -1;
}

# SQUEEZELITE
$response{'instanceenabled'} = 0;
for (my $instance = 1; $instance <= $cfg->param("Main.Instances"); $instance++) {
	my $enabled = $cfg->param("Instance" . $instance . ".Enabled");
	if (is_enabled($enabled)) {
		$response{'instanceenabled'} += 1;
	}
}

$response{'instancecount'} = trim(`pgrep -c squeezelite`);

print_response();

sub print_response
{
	if($error) {
		print $cgi->header(
			-type => 'application/json',
			-charset => 'utf-8',
			-status => '400 Bad Request',
		);	
		$response{'error'} = $error;
	} else {
		# Return something
		print $cgi->header(
			-type => 'application/json',
			-charset => 'utf-8',
			-status => '200 OK',
		);	
	}	
	
	print encode_json(\%response);

}
