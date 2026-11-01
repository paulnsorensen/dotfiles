#!/usr/bin/env bash
# Print the effective logging settings.
# An empty value is a deliberate override. Only an unset variable takes the default.

if [ -z "${LOG_LEVEL+set}" ]; then
  LOG_LEVEL=info
fi
if [ -z "${LOG_FILE+set}" ]; then
  LOG_FILE=/var/log/app.log
fi
if [ -z "${COLOR+set}" ]; then
  COLOR=auto
fi
if [ "$COLOR" = "auto" ]; then
  if [ -n "$NO_COLOR" ]; then
    COLOR=never
  else
    COLOR=always
  fi
fi
echo "level=[$LOG_LEVEL] file=[$LOG_FILE] color=[$COLOR]"
