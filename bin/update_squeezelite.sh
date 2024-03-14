#!/bin/bash

# SQUEEZELITE UPDATE
# "stolen" from MS4H - thanks!

# Vars
pluginname=$(perl -e 'use LoxBerry::System; print $lbpplugindir; exit;')

squp_url="https://github.com/ralph-irving/squeezelite/"
squp_url_version="https://raw.githubusercontent.com/ralph-irving/squeezelite/master/squeezelite.h"
dir="`mktemp --directory`"
cd "$dir"

# print out versions
if [[ $1 == "current" || $1 == "" ]]; then
	. $LBHOMEDIR/libs/bashlib/iniparser.sh
	iniparser $LBPCONFIG/$pluginname/plugin_squeezelite.cfg "Main"
	if [[ $MainUseAlternativeBinaries == "1" ]]; then
		SQUEEZEBIN="${LBPDATA}/${pluginname}/squeezelite"
	else
		SQUEEZEBIN=`which squeezelite`
	fi
	versinstall=`$SQUEEZEBIN -? | grep "Squeezelite v" | awk '{print $2}' | cut -d "v" -f2 | cut -d "," -f1`
	if [[ $1 != "" ]]; then
		echo -n $versinstall
		exit 0
	fi
fi
if [[ $1 == "available" || $1 == "" ]]; then
	wget -t 5 -q -O /tmp/sqo.version $squp_url_version
	versonline0=$(grep "#define MAJOR_VERSION" /tmp/sqo.version | awk '{print $3}' | sed 's/\"/ /g' | sed 's/ //g' )
	versonline1=$(grep "#define MINOR_VERSION" /tmp/sqo.version | awk '{print $3}' | sed 's/\"/ /g' | sed 's/ //g' )
	versonline2=$(grep "#define MICRO_VERSION" /tmp/sqo.version | awk '{print $3}' | sed 's/\"/ /g' | sed 's/ //g' )
	versonline=$(echo "$versonline0.$versonline1-$versonline2")
	rm /tmp/sqo.version
	if [[ $1 != "" ]]; then
		echo -n $versonline
		exit 0
	fi
fi

# Logging
. $LBHOMEDIR/libs/bashlib/loxberry_log.sh
PACKAGE=$pluginname
NAME=squeezelite_upgrade
FILENAME=${LBPLOG}/${PACKAGE}/squeezelite_upgrade.log
STDERR=1
LOGLEVEL=7
LOGSTART "Squeezelite upgrade started."

dir="`mktemp --directory`"
cd "$dir"
LOGINF "Squeezelite | UPDATE"
LOGINF "Version online:      "$versonline
LOGINF "Version installed:   "$versinstall

LOGINF "Download Squeezelite..."
git clone $squp_url

LOGINF "Compile Squeezelite..."
cd squeezelite
CORES=$(grep ^processor /proc/cpuinfo | wc -l)
make -j $CORES

LOGINF "Install new version..."
cp -f squeezelite ${LBPDATA}/${pluginname}/squeezelite
sudo systemctl stop squeezelite.service
sudo systemctl disable squeezelite

if [ -e ${LBPDATA}/${pluginname}/squeezelite ]; then
	newversinstall=`${LBPDATA}/${pluginname}/squeezelite -? | grep "Squeezelite v" | awk '{print $2}' | cut -d "v" -f2 | cut -d "," -f1`
fi

if [[ $newversinstall == $versonline ]]; then
	LOGOK "SUCCESSFULLY UPDATED! New version is: $newversinstall"
else 
	LOGERR "ERROR WHILE UPDATING! Keeping old version."
fi

LOGEND "Upgrading squeezelite finished."
exit 0
