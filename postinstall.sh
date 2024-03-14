#!/bin/sh

# Bashscript which is executed by bash *AFTER* complete installation is done
# (but *BEFORE* postupdate). Use with caution and remember, that all systems
# may be different! Better to do this in your own Pluginscript if possible.
#
# Exit code must be 0 if executed successfull.
#
# Will be executed as user "loxberry".
#
# We add 5 arguments when executing the script:
# command <TEMPFOLDER> <NAME> <FOLDER> <VERSION> <BASEFOLDER>
#
# For logging, print to STDOUT. You can use the following tags for showing
# different colorized information during plugin installation:
#
# <OK> This was ok!"
# <INFO> This is just for your information."
# <WARNING> This is a warning!"
# <ERROR> This is an error!"
# <FAIL> This is a fail!"

# To use important variables from command line use the following code:
ARGV0=$0 # Zero argument is shell command
ARGV1=$1 # First argument is temp folder during install
ARGV2=$2 # Second argument is Plugin-Name for scipts etc.
ARGV3=$3 # Third argument is Plugin installation folder
ARGV4=$4 # Forth argument is Plugin version
ARGV5=$5 # Fifth argument is Base folder of LoxBerry

echo "<INFO> Determining if we are running on Raspberry"
# DietPi
if [ -e /boot/dietpi/func/dietpi-obtain_hw_model ]; then
	HWMODELFILENAME=$(cat /boot/dietpi/func/dietpi-obtain_hw_model | grep "G_HW_MODEL $G_HW_MODEL " | awk '/.*G_HW_MODEL .*/ {for(i=4; i<=NF; ++i) printf "%s_", $i; print ""}' | sed 's/\//_/g' | sed 's/[()]//g' | sed 's/_$//' | tr '[:upper:]' '[:lower:]')
	if echo $HWMODELFILENAME | grep -q "raspberry"; then
		echo "Raspbian" > $ARGV5/config/plugins/$ARGV2/is_raspbian.info
		echo "<OK> Running on a Raspberry Pi"
	else
		echo "<OK> This is not Raspberry hardware"
	fi
# Raspbian
else
	cat /etc/os-release | grep "ID=raspbian" > /dev/null
	if [ $? -eq 0 ] ; then
		echo "Raspbian" > $ARGV5/config/plugins/$ARGV2/is_raspbian.info
		echo "<OK> Running on a Raspberry Pi"
	else
		echo "<OK> This is not Raspberry hardware"
	fi
fi

echo "<INFO> Compiling newest Squeezelite binaries"
echo "<INFO> --------------------------------------------------------------"
$ARGV5/bin/plugins/$ARGV2/update_squeezelite.sh
echo "<INFO> --------------------------------------------------------------"

# Exit with Status 0
exit 0
