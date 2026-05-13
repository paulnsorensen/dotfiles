# Shell / Bash Anti-Patterns

## 1. Unquoted variables

The #1 shell bug. Breaks on spaces, globs, and empty values.

```bash
# SLOP
for file in $files; do
    rm $file
done

# CLEAN
for file in "${files[@]}"; do
    rm -- "$file"
done
```

Quote every variable expansion: `"$var"`, `"${array[@]}"`, `"$(command)"`.
The `--` stops option parsing (protects against filenames starting with `-`).

## 2. Missing or incomplete `set -euo pipefail`

AI scripts either omit strict mode entirely or use partial `set -e` without
`-u` and `-o pipefail`. Both are dangerous.

```bash
# SLOP — no strict mode
#!/bin/bash
cd /some/directory    # Might fail silently
rm -rf build/         # Now you're deleting in the wrong place

# SLOP — partial strict mode (common AI output)
#!/bin/bash
set -e
yq '.items[]' file.yaml | while read -r item; do  # yq failure silently ignored
    process "$item"
done

# CLEAN
#!/bin/bash
set -euo pipefail
cd /some/directory
rm -rf build/
```

- `-e`: Exit on error
- `-u`: Error on undefined variables (catches typos like `$UESR` instead of `$USER`)
- `-o pipefail`: Pipeline fails if any command fails (not just the last)

All three flags together. `set -e` alone is a half-measure — especially
dangerous in scripts that pipe through `jq`/`yq`/`grep` where a failure
on the left side is silently swallowed.

## 3. Parsing `ls` output

`ls` output is not machine-readable. Filenames with spaces, newlines,
or special characters break everything.

```bash
# SLOP
for file in $(ls *.txt); do
    process "$file"
done

# CLEAN — glob directly
for file in *.txt; do
    [[ -f "$file" ]] && process "$file"
done

# CLEAN — fd for complex searches
fd -e txt -x process {}
```

## 4. Useless use of `cat`

```bash
# SLOP
cat file.txt | grep "pattern"
cat file.txt | wc -l

# CLEAN
grep "pattern" file.txt
wc -l < file.txt
```

## 5. Backticks instead of `$()`

Backticks don't nest and are harder to read.

```bash
# SLOP
result=`command`
nested=`echo \`date\``

# CLEAN
result=$(command)
nested=$(echo "$(date)")
```

## 6. `[ ]` instead of `[[ ]]`

`[[ ]]` is safer: no word splitting, supports regex, no quoting surprises.

```bash
# SLOP
if [ $var = "value" ]; then
if [ -z $maybe_empty ]; then

# CLEAN
if [[ "$var" == "value" ]]; then
if [[ -z "${maybe_empty:-}" ]]; then
```

## 7. Hardcoded paths

AI writes absolute paths or assumes CWD.

```bash
# SLOP
source /home/user/project/lib/utils.sh
config_file=./config.yaml

# CLEAN
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/utils.sh"
config_file="${SCRIPT_DIR}/config.yaml"
```

## 8. Not using `readonly` for constants

```bash
# SLOP
MAX_RETRIES=3
BASE_URL="https://api.example.com"

# CLEAN
readonly MAX_RETRIES=3
readonly BASE_URL="https://api.example.com"
```

## 9. Using `echo` for error messages

Errors go to stderr, not stdout.

```bash
# SLOP
echo "Error: file not found"
exit 1

# CLEAN
echo >&2 "Error: file not found"
exit 1

# Or with a helper
die() { echo >&2 "$@"; exit 1; }
die "file not found"
```
