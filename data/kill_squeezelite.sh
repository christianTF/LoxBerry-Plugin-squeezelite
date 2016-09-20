#!/bin/sh
kill $(ps aux | grep 'squeezelite' | awk '{print $2}')
