#!/usr/bin/env bash
# Print the deploy URL and replica count for an environment name.

env_name=$1

if [ "$env_name" = "dev" ]; then
  url="https://dev.example.internal"
  replicas=1
elif [ "$env_name" = "staging" ]; then
  url="https://staging.example.internal"
  replicas=2
elif [ "$env_name" = "prod" ]; then
  url="https://example.com"
  replicas=6
elif [ "$env_name" = "production" ]; then
  url="https://example.com"
  replicas=6
else
  echo "unknown environment: $env_name" >&2
  exit 64
fi

echo "url=$url"
echo "replicas=$replicas"
