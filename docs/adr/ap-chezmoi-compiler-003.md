# ADR-003: Block on live drift from scratch chezmoi baseline by default

- **Context:** Compiling whole merged settings from live files would silently absorb local drift into generated output, while compiling only from repo/chezmoi seed state could silently overwrite local drift.
- **Decision:** Render a scratch chezmoi baseline, compile from that baseline, compare baseline/live/compiled files, show grouped diffs, and block by default with one yes/no prompt. `dots sync --accept-agent-drift` accepts drift for that run only.
- **Alternatives:** Warn-only drift is less disruptive but can still overwrite unnoticed. Blocking on only managed-key drift misses user-owned drift that should be consciously reviewed. Updating the baseline from live drift risks absorbing junk.
- **Consequences:** Drift becomes visible before apply and noninteractive sync fails safely unless the override flag is passed. Users may need to resolve or consciously accept existing drift during the first migration run.
