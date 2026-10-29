#!/usr/bin/env bash
# Print "name id" pairs from an "id,name" CSV file, sorted by name.

cut -d, -f1 "$1" > /tmp/ids.$$
cut -d, -f2 "$1" > /tmp/names.$$
paste -d' ' /tmp/names.$$ /tmp/ids.$$ > /tmp/pairs.$$
sort /tmp/pairs.$$ > /tmp/sorted_pairs.$$
lines=$(wc -l < /tmp/sorted_pairs.$$)
echo "users: $lines"
cat /tmp/sorted_pairs.$$
rm -f /tmp/ids.$$ /tmp/names.$$ /tmp/pairs.$$ /tmp/sorted_pairs.$$
