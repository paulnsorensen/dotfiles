#!/usr/bin/env bash
# Turn branch names from stdin into "prefix:rest" tag slugs.

while read -r branch; do
  if [ -z "$branch" ]; then
    continue
  fi
  slug=$(echo "$branch" | sed 's/\//-/g')
  slug=$(echo "$slug" | sed 's/_/-/g')
  prefix=$(echo "$slug" | cut -d- -f1)
  rest=$(echo "$slug" | cut -d- -f2-)
  if [ "$prefix" = "$slug" ]; then
    rest=""
  fi
  echo "$prefix:$rest"
done
