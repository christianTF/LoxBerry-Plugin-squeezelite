#!/bin/sh
/bin/kill $(ps aux | grep 'squeezelite' | awk '{print $2}')
