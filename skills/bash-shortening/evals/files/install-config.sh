#!/usr/bin/env bash
# Install a config file only when it carries the managed marker.

src=$1
dest_dir=$2

if grep -q '^# managed' "$src"; then
  if [ -f "$dest_dir/app.conf" ]; then
    cp "$dest_dir/app.conf" "$dest_dir/app.conf.bak"
  fi
  cp "$src" "$dest_dir/app.conf"
  echo "installed $src"
else
  echo "skipped $src: no managed marker"
fi
