#!/usr/bin/perl
use POSIX 'strftime';
use File::HomeDir;
use Config::Simple;
use warnings;
use strict;
no strict "refs"; # we need it for template system
use Cwd 'abs_path';

	my $command = "su -c ";
	$command .= "\"squeezelite -a 80 -n Testinstanz &\"";
	# $command .= " -f $installfolder/log/plugins/$pluginname/squeezelite_" . ($instance+1) . ".log 
	$command .= " squeezeplay";
	$command .= " > /dev/null ";
	# Starten
	system($command);
