#!/bin/sh

loxberryhome=REPLACELBHOMEDIR
pluginname=REPLACELBPPLUGINDIR
PIDFILES=/run/shm/lms2udp.*

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
rm -f $PIDFILES

$loxberryhome/bin/plugins/$pluginname/lms2udp.pl & 1> /dev/null 2> $loxberryhome/log/plugins/$pluginname/lms2udp.log