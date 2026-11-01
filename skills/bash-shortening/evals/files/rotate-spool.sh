#!/usr/bin/env bash
# Move the .msg files of a spool directory into its archive and log each step.

spool=$1

echo "[rotate] [INFO] starting rotation in $spool"
if [ ! -d "$spool" ]; then
  echo "[rotate] [ERROR] missing spool directory: $spool"
  exit 1
fi
if [ ! -d "$spool/archive" ]; then
  echo "[rotate] [INFO] creating $spool/archive"
  mkdir "$spool/archive"
fi
for f in "$spool"/*.msg; do
  if [ ! -e "$f" ]; then
    echo "[rotate] [WARN] no messages to rotate"
    break
  fi
  echo "[rotate] [INFO] archiving $(basename "$f")"
  mv "$f" "$spool/archive/"
done
echo "[rotate] [INFO] done"
