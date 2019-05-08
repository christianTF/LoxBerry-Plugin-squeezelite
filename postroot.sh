#!/bin/bash
# Will be executed as user "root".

loxberryhome=REPLACELBHOMEDIR
pluginname=REPLACELBPPLUGINDIR
datadir=REPLACELBPDATADIR

#
# Upgrade routines from V0.x to V1.x
#

# Removing user squeezelox
id -u "squeezelox" > /dev/null
if [ $? -eq 0 ] ; then
	echo "<INFO> Upgrade to V1.x: Deleting user squeezelox"
	deluser --remove-home squeezelox
fi

if [ -e $datadir/squeezelite ]; then
	echo "<INFO> Upgrade to V1.x: Deleting old squeezelite symlink"
	rm -f $datadir/squeezelite
fi

if [ -e $loxberryhome/config/plugins/$pluginname/sudoers.* ]; then
	echo "<INFO> Upgrade to V1.x: Removing obsolete sudoers version files"
	rm $loxberryhome/config/plugins/$pluginname/sudoers.*
fi
	

#
# Upgrade finished
#

# Disable Squeezelite Service in systemd

if [ `systemctl is-active squeezelite.service` ]; then
	echo "<INFO> Disabling Squeezelite systemd service"
	systemctl stop squeezelite.service
	systemctl disable squeezelite.service
fi

# Set alternative binaries to be executable
chmod +x $loxberryhome/data/plugins/$pluginname/squeezelite*

exit 0
