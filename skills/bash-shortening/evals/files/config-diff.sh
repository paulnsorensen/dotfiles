#!/usr/bin/env bash
# Compare two config files, ignoring comments and blank lines.
# Exit status: 0 when the settings match, 1 when they differ.

grep -v '^#' "$1" | grep -v '^$' | sort > /tmp/left.$$
grep -v '^#' "$2" | grep -v '^$' | sort > /tmp/right.$$

if diff /tmp/left.$$ /tmp/right.$$ > /tmp/delta.$$; then
  echo "configs match"
  status=0
else
  echo "configs differ:"
  cat /tmp/delta.$$
  status=1
fi
rm -f /tmp/left.$$ /tmp/right.$$ /tmp/delta.$$
exit $status
