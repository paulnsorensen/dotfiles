#!/usr/bin/env bash
# Print the scheme, host, port, and path of each URL argument.

for url in "$@"; do
  scheme=$(echo "$url" | sed 's|://.*||')
  rest=$(echo "$url" | sed 's|^[a-z]*://||')
  hostport=$(echo "$rest" | cut -d/ -f1)
  path=$(echo "$rest" | cut -s -d/ -f2-)
  host=$(echo "$hostport" | cut -d: -f1)
  port=$(echo "$hostport" | cut -s -d: -f2)
  if [ -z "$port" ]; then
    if [ "$scheme" = "https" ]; then
      port=443
    else
      port=80
    fi
  fi
  echo "$scheme $host $port /$path"
done
