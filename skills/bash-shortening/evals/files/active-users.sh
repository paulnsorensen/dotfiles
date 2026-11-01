#!/usr/bin/env bash
# Print the active users from a CSV report and count them.
# The first three CSV columns are name,email,status.
set -euo pipefail

report=$1

if ! grep -v '^name,' "$report" > /tmp/rows.$$; then
  echo "no data rows in $report"
  rm -f /tmp/rows.$$
  exit 3
fi

active=0
while read -r line; do
  name=$(echo "$line" | cut -d, -f1)
  email=$(echo "$line" | cut -d, -f2)
  status=$(echo "$line" | cut -d, -f3)
  if [ "$status" = "active" ]; then
    echo "$name <$email>"
    active=$((active + 1))
  fi
done < /tmp/rows.$$
rm -f /tmp/rows.$$

echo "active users: $active"
