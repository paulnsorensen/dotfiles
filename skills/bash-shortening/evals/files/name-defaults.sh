#!/usr/bin/env bash
# Build a release archive name from optional settings.

APP_NAME=$1
VERSION=$2
CHANNEL=$3

if [ -z "$APP_NAME" ]; then
  APP_NAME="app"
fi
if [ -z "$VERSION" ]; then
  VERSION="0.0.0"
fi
if [ -z "$CHANNEL" ]; then
  CHANNEL="stable"
fi

safe_name=$(echo "$APP_NAME" | sed 's/ /-/g')
safe_name=$(echo "$safe_name" | tr '[:upper:]' '[:lower:]')
short_version=$(echo "$VERSION" | cut -c1-5)
name_bytes=$(echo -n "$safe_name" | wc -c)

echo "archive: ${safe_name}-${short_version}-${CHANNEL}.tar.gz"
echo "name bytes: $name_bytes"
