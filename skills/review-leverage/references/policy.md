# review-leverage policy file

The file `.review-leverage.toml` is optional. The script reads it only from
`origin/<default>`. Merge a policy change to the default branch before it
takes effect.

```toml
# Walk this many `should` areas after every `must` area. Range 0..20.
should_budget = 3

# Any changed file that matches these globs is a `policy-must` area.
must_paths = ["src/billing/**"]

# Files that match these globs are `low-signal` (skipped). This does not skip
# a `gate-mute` or `test-oracle` area.
skip_paths = ["vendor/**"]

# Add globs to a builtin path group. Groups: gate-mute, test, auth-security,
# schema, api, agent-config.
[paths]
gate-mute = ["tests/lib/affected.py"]
auth-security = ["src/session/**"]
```

Rules:

- Every key is append-only. A repo cannot remove a builtin glob.
- An unknown key or a bad type stops `rank` with exit 2.
- Globs follow gitignore style. A pattern without `/` matches a basename at
  any depth. `**/` matches zero or more directories.
- The run file and every ledger line record the policy source as
  `builtin+origin/<default>:.review-leverage.toml@<blob>`.
