#!/usr/bin/env bash
# Warn when a mount in a usage report crosses the thresholds.
# Input: lines of "mount used_percent" on stdin.

warn=$1
crit=$2
if [ -z "$warn" ]; then warn=80; fi
if [ -z "$crit" ]; then crit=90; fi

status=0
while read -r mount used; do
  used=$(echo "$used" | tr -d '%')
  if [ $used -ge $crit ]; then
    echo "CRITICAL $mount ${used}%"
    status=2
  elif [ $used -ge $warn ] && [ $status -lt 1 ]; then
    echo "WARNING $mount ${used}%"
    status=1
  elif [ $used -ge $warn ]; then
    echo "WARNING $mount ${used}%"
  fi
done

if [ $status -eq 0 ]; then
  echo "all mounts below ${warn}%"
fi
exit $status
