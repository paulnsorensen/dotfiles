#!/usr/bin/env bash
# Create the project skeleton in the current directory.

if [ ! -d src ]; then mkdir src; fi
if [ ! -d tests ]; then mkdir tests; fi
if [ ! -d docs ]; then mkdir docs; fi
mkdir -p src/lib
mkdir -p src/bin
for i in 1 2 3 4 5; do
  if [ ! -d "tests/case0$i" ]; then
    mkdir "tests/case0$i"
  fi
  touch "tests/case0$i/input.txt"
done
for n in 2 4 6 8 10; do
  touch "docs/chapter-$n.md"
done
echo "created $(find . -type d | wc -l) directories and $(find . -type f | wc -l) files"
