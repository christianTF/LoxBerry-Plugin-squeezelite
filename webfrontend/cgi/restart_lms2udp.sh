#!/bin/sh

# PID location from Perl
# my $pidfile = "/var/run/lms2udp.$$";
PIDFILES=/var/run/lms2udp.*
PLUGINBASEPATH=/opt/loxberry/webfrontend/cgi/plugins/squeezelite

# Stop running processes
if [ -e  $PIDFILES ] 
then
	for file in $PIDFILES
	do
		extension="${file##*.}"
		echo "Processing PID $extension"
		/bin/kill -SIGTERM $extension
	done
fi

# Cleanup remaining pidfiles
rm $PIDFILES

perl $PLUGINBASEPATH/bin/lms2udp.pl
