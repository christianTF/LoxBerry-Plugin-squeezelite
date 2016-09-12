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

$pluginname = abs_path($0);
$pluginname =~ s/(.*)\/(.*)\/(.*)$/$2/g;
# Read Settings
$cfg             = new Config::Simple("$installfolder/config/plugins/$pluginname/plugin_squeezelite.cfg");
$installfolder   = $cfg->param("BASE.INSTALLFOLDER");



exit;
