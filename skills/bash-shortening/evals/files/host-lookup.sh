#!/usr/bin/env bash
# Look up hosts in a hosts file and print their addresses.
# Exit status: 0 when every host is found, 2 at the first missing host.

lookup() {
  local entry
  entry=$(grep -w "$2" "$1")
  if [ $? -ne 0 ]; then
    return 2
  fi
  echo "$entry" | awk '{print $1}'
}

hosts_file=$1
shift
for host in "$@"; do
  addr=$(lookup "$hosts_file" "$host")
  status=$?
  if [ $status -eq 0 ]; then
    echo "$host -> $addr"
  else
    echo "$host: not found"
    exit $status
  fi
done
