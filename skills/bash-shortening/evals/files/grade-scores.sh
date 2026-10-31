#!/usr/bin/env bash
# Grade each "name score" line from stdin and report a summary.

pass=0
fail=0
while read -r name score; do
  if [ $score -ge 90 ]; then
    grade="high"
  elif [ $score -ge 50 ]; then
    grade="medium"
  else
    grade="low"
  fi
  if [ $score -ge 50 ]; then
    pass=`expr $pass + 1`
  else
    fail=`expr $fail + 1`
  fi
  echo "$name $grade"
done

total=`expr $pass + $fail`
if [ $total -gt 0 ] && [ $pass -gt $fail ]; then
  echo "summary: $pass/$total passed (majority)"
else
  echo "summary: $pass/$total passed"
fi
