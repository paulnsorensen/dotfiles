#!/usr/bin/env bash
# Compare two word lists, ignoring order, and count added and removed lines.
set -euo pipefail

old_list=$1
new_list=$2

sort "$old_list" > /tmp/sorted_old.$$
sort "$new_list" > /tmp/sorted_new.$$
diff /tmp/sorted_old.$$ /tmp/sorted_new.$$ > /tmp/changes.$$ || true

added=0
removed=0
while read -r line; do
  first=$(echo "$line" | cut -c1)
  if [ "$first" = ">" ]; then
    added=$(expr $added + 1)
  fi
  if [ "$first" = "<" ]; then
    removed=$(expr $removed + 1)
  fi
done < /tmp/changes.$$

rm /tmp/sorted_old.$$ /tmp/sorted_new.$$ /tmp/changes.$$

echo "added: $added"
echo "removed: $removed"
