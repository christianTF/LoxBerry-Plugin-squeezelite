#!/bin/sh

loxberryhome=REPLACEINSTALLFOLDER
pluginname=REPLACEFOLDERNAME
PIDFILES=/run/shm/lms2udp.*

# Directory/Pluginname fallback for test environment
if [ ! -d $loxberryhome ]; then
	loxberryhome=/opt/loxberry
fi
if [ ! -d $pluginname ]; then
	pluginname=squeezelite
fi


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

$loxberryhome/webfrontend/cgi/plugins/$pluginname/bin/lms2udp.pl & 1> /dev/null 2> $loxberryhome/log/plugins/$pluginname/lms2udp.log