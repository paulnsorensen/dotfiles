#!/usr/bin/env bash
# Compare two config files, ignoring comment lines and blank lines.
# A '#' after a value is part of the value, for example url=http://host/#top.
# Exit status: 0 when the settings match, 1 when they differ, 2 when a file is unreadable.

for f in "$1" "$2"; do
  if [[ ! -r $f ]]; then
    echo "cannot read $f"
    exit 2
  fi
done

grep -v '^#' "$1" | grep -v '^$' | sort > /tmp/left.$$
grep -v '^#' "$2" | grep -v '^$' | sort > /tmp/right.$$

diff /tmp/left.$$ /tmp/right.$$ > /tmp/delta.$$
status=$?
if [ $status -eq 0 ]; then
  echo "configs match"
else
  echo "configs differ:"
  cat /tmp/delta.$$
fi
rm -f /tmp/left.$$ /tmp/right.$$ /tmp/delta.$$
exit $status
