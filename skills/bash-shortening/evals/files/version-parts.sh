#!/usr/bin/env bash
# Split a version string like 1.2.3-rc1 into its parts and print the next patch version.

version=$1
if [ -z "$version" ]; then
  version=$(cat VERSION)
fi
core=$(echo "$version" | cut -d- -f1)
pre=$(echo "$version" | cut -s -d- -f2-)
major=$(echo "$core" | cut -d. -f1)
minor=$(echo "$core" | cut -d. -f2)
patch=$(echo "$core" | cut -d. -f3)
next_patch=$(expr $patch + 1)
echo "major=$major minor=$minor patch=$patch pre=${pre:-none}"
echo "next=$major.$minor.$next_patch"
