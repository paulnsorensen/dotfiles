#!/usr/bin/env bash
# Retry a flaky step until it succeeds or the attempts run out.
# The step reads its outcomes from the file named in $1, one line per attempt.

outcomes=$1
max_attempts=$2
if [ -z "$max_attempts" ]; then
  max_attempts=3
fi

attempt=1
while [ $attempt -le $max_attempts ]; do
  result=$(sed -n "${attempt}p" "$outcomes")
  if [ "$result" = "ok" ]; then
    echo "attempt $attempt: ok"
    exit 0
  fi
  echo "attempt $attempt: failed"
  delay=`expr $attempt \* 2`
  echo "waiting ${delay}s (simulated)"
  attempt=`expr $attempt + 1`
done

echo "gave up after $max_attempts attempts"
exit 1
