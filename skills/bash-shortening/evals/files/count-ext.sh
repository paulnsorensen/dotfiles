#!/usr/bin/env bash
# Count the files below the current directory by extension.

declare -A counts
for f in $(find . -type f); do
  name=$(basename "$f")
  if echo "$name" | grep -q '\.'; then
    ext=$(echo "$name" | sed 's/.*\.//')
  else
    ext="(none)"
  fi
  if [ -z "${counts[$ext]}" ]; then
    counts[$ext]=0
  fi
  counts[$ext]=$(expr ${counts[$ext]} + 1)
done
for ext in $(echo "${!counts[@]}" | tr ' ' '\n' | sort); do
  echo "$ext ${counts[$ext]}"
done
