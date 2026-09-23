# Process substitution and redirection

Examples 27-31 from the source article. Process substitution
(`<(cmd)`, `>(cmd)`) lets you treat command output as a file path, which
unlocks a class of rewrites where the command would otherwise demand a
real file.

Bashism — does not work in `/bin/sh`.

## Example 27 — `diff` two pipelines

```bash
# Before
sort file1.txt > /tmp/sorted1.txt
sort file2.txt > /tmp/sorted2.txt
diff /tmp/sorted1.txt /tmp/sorted2.txt
rm /tmp/sorted1.txt /tmp/sorted2.txt

# After
diff <(sort file1.txt) <(sort file2.txt)
```

Bash creates `/dev/fd/63` and `/dev/fd/62` (or named pipes), runs the
inner commands writing to them, and passes the paths to `diff`. No
disk, no cleanup, no race.

## Example 28 — Concatenate two command outputs

```bash
# Before
find /var/log -name "*.log" > /tmp/logs.txt
find /opt/logs -name "*.log" >> /tmp/logs.txt
cat /tmp/logs.txt
rm /tmp/logs.txt

# After
cat <(find /var/log -name "*.log") <(find /opt/logs -name "*.log")
```

Or, if you don't need them ordered, run them in parallel inside a subshell
and let the OS interleave:

```bash
( find /var/log -name "*.log" & find /opt/logs -name "*.log" & wait )
```

That trades ordering for speed. Pick by what the consumer needs.

## Example 29 — Feed a `while read` loop from a command

```bash
# Before
ps aux > /tmp/processes.txt
while read -r line; do
  echo "Process: $line"
done < /tmp/processes.txt
rm /tmp/processes.txt

# After
while read -r line; do
  echo "Process: $line"
done < <(ps aux)
```

**Critical detail — the space matters.** `done < <(...)` is `<` (input
redirection) feeding from `<(...)` (process substitution). Without the
space, `<<(` is a parse error.

**Why this matters more than `ps aux | while read`.** A pipeline runs the
right-hand side in a subshell, so any variables you set inside the loop
don't survive after `done`:

```bash
count=0
ps aux | while read -r _; do ((count++)); done
echo "$count"                     # 0 — increment happened in subshell

count=0
while read -r _; do ((count++)); done < <(ps aux)
echo "$count"                     # 174 — same shell, var persisted
```

Use `< <(...)` whenever the loop body needs to mutate state visible
afterward. This is the single most useful process-substitution pattern.

## Example 30 — Pipeline replaces temp file (with `jq`)

```bash
# Before
curl -s https://api.example.com/data > /tmp/api_data.json
jq '.items[]' /tmp/api_data.json > /tmp/items.json
cat /tmp/items.json
rm /tmp/api_data.json /tmp/items.json

# After
curl -s https://api.example.com/data | jq '.items[]'
```

This isn't process substitution per se — it's plain pipelining. Listed
in the article alongside `<( )` because the *anti-pattern* it replaces
(temp files) is the same.

## Example 31 — Multiple process subs into a join

```bash
# Before
curl -s https://api.example.com/users > /tmp/users.json
curl -s https://api.example.com/roles > /tmp/roles.json
join -j 1 \
  <(jq -r '.[].id'     /tmp/users.json) \
  <(jq -r '.[].userId' /tmp/roles.json)
rm /tmp/users.json /tmp/roles.json

# After
join -j 1 \
  <(curl -s https://api.example.com/users | jq -r '.[].id') \
  <(curl -s https://api.example.com/roles | jq -r '.[].userId')
```

Both `curl` calls run in parallel (process substitution backgrounds them),
both `jq` runs filter their stream, `join` consumes from the two named
pipes. Zero temp files for what was a 5-step process.

## Output process substitution: `>(cmd)`

The article doesn't cover this, but it completes the picture. `>(cmd)`
gives you a file path that, when written to, feeds `cmd`'s stdin.

```bash
# Tee output to two compressors at once
tar c /data | tee >(gzip > backup.tar.gz) >(xz > backup.tar.xz) > /dev/null

# Log a command's output to multiple destinations
./build.sh 2> >(tee build.err >&2) > >(tee build.out)
```

Powerful for logging and parallel sinks; rare in everyday scripts.

## Here-strings: `<<<`

Closely related and often the right tool when you'd otherwise `echo "$x" | cmd`:

```bash
# Before
echo "$JSON" | jq -r '.name'

# After
jq -r '.name' <<<"$JSON"
```

`<<<` feeds the string as stdin without spawning `echo`. Same use case as
process substitution — eliminate a subprocess — but for a literal value,
not a command.

## When process substitution doesn't work

- **Commands that need a real seekable file** (e.g. `mmap`-style readers,
  some media tools). `/dev/fd/N` is a pipe; you can't `seek` it. Test
  before assuming.
- **Tools that re-open the path multiple times.** Process substitution
  yields a single read of the producer's output. Tools that open the
  same path twice get an empty file the second time.
- **Non-bash shells.** Falls back to `mktemp` + `trap rm`.
