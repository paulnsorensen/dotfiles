#!/usr/bin/env bash
# Print "name id" pairs from an "id,name[,extra...]" CSV file, sorted by name.
# Rows may carry extra columns after the name; only the first two count.

cut -d, -f1 "$1" > /tmp/ids.$$
cut -d, -f2 "$1" > /tmp/names.$$
paste -d' ' /tmp/names.$$ /tmp/ids.$$ > /tmp/pairs.$$
sort /tmp/pairs.$$ > /tmp/sorted_pairs.$$
lines=`wc -l < /tmp/sorted_pairs.$$`
echo "users: $lines"
cat /tmp/sorted_pairs.$$
rm -f /tmp/ids.$$ /tmp/names.$$ /tmp/pairs.$$ /tmp/sorted_pairs.$$
