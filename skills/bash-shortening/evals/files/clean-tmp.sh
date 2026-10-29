#!/usr/bin/env bash
# Delete the .tmp files below a directory and report how many were removed.

dir=${1:-.}
count=0
find "$dir" -type f -name '*.tmp' > /tmp/doomed.$$
while IFS= read -r f; do
  rm "$f"
  count=$((count + 1))
done < /tmp/doomed.$$
rm -f /tmp/doomed.$$
echo "removed $count file(s)"
