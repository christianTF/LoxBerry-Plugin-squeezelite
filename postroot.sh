#!/bin/bash
# Will be executed as user "root".

#
# Upgrade routines from V0.x to V1.x
#

# Removing user squeezelox
id -u "squeezelox" > /dev/null
if [ $? -eq 0 ] ; then
	echo "<INFO> Upgrade to V1.x: Deleting user squeezelox"
	deluser --remove-home squeezelox
fi

#
# Upgrade finished
#

# Disable Squeezelite Service in systemd

if [ `systemctl is-active squeezelite.service` ]
	then
		/usr/bin/logger "loxberry-plugin-$pluginname - Disabling squeezelite.service"
		systemctl stop squeezelite.service
		systemctl disable squeezelite.service
fi




exit 0
