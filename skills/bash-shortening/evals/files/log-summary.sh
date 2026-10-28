#!/usr/bin/env bash
# Summarize the .log files under a directory: lines per file, then totals.

dir=$1
if [ -z "$dir" ]; then
  dir=.
fi

find "$dir" -type f -name '*.log' | sort > /tmp/logfiles.$$

files=0
total=0
while IFS= read -r f; do
  n=$(cat "$f" | wc -l)
  echo "$(basename "$f"): $n"
  files=$(expr $files + 1)
  total=$(expr $total + $n)
done < /tmp/logfiles.$$
rm -f /tmp/logfiles.$$

echo "files=$files total=$total"
