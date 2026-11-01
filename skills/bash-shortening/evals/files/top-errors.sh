#!/usr/bin/env bash
# Report the three most frequent error codes in a log file.
# A log with no ERROR lines, or a missing log, prints "no errors" and exits 0.
set -euo pipefail

log=$1

grep 'ERROR' "$log" > /tmp/errors.$$ 2>/dev/null || true
count=`cat /tmp/errors.$$ | wc -l`
if [ $count -eq 0 ]; then
  echo "no errors"
  rm -f /tmp/errors.$$
  exit 0
fi

cut -d' ' -f3 /tmp/errors.$$ > /tmp/codes.$$
sort /tmp/codes.$$ > /tmp/sorted.$$
uniq -c /tmp/sorted.$$ > /tmp/counted.$$
sort -rn /tmp/counted.$$ > /tmp/ranked.$$
echo "errors: $count"
head -3 /tmp/ranked.$$
rm -f /tmp/errors.$$ /tmp/codes.$$ /tmp/sorted.$$ /tmp/counted.$$ /tmp/ranked.$$
