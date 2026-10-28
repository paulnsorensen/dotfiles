#!/usr/bin/env bash
# List the file names that exist in the first directory but not in the second.

src=$1
dst=$2

ls "$src" | sort > /tmp/src_names.$$
ls "$dst" | sort > /tmp/dst_names.$$
comm -23 /tmp/src_names.$$ /tmp/dst_names.$$ > /tmp/missing.$$

count=$(cat /tmp/missing.$$ | wc -l)
if [ $count -eq 0 ]; then
  echo "in sync"
else
  echo "missing from $dst:"
  cat /tmp/missing.$$
fi
rm -f /tmp/src_names.$$ /tmp/dst_names.$$ /tmp/missing.$$
