#!/usr/bin/env bash
# Print the directory, file name, stem, and extension of each path argument.

for p in "$@"; do
  dir=$(dirname "$p")
  file=$(basename "$p")
  stem=$(echo "$file" | sed 's/\.[^.]*$//')
  if echo "$file" | grep -q '\.'; then
    ext=$(echo "$file" | sed 's/.*\.//')
  else
    ext="none"
  fi
  echo "path=$p"
  echo "  dir=$dir file=$file stem=$stem ext=$ext"
done
