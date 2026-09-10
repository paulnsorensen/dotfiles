# Remove retired skills before refresh

`install-external.sh` must snapshot retired source-owned skills before `npx skills add` refreshes the source.

The `skills` CLI rewrites `~/.agents/.skill-lock.json` during an add. When an upstream skill disappears, this rewrite removes its source record but leaves its copied directory. A later `skills list --global --json` then reports the directory with `source: null`. Source-filtered cleanup cannot identify or remove it.

`chezmoi/lib/install-external.sh:216-245` now computes the stale set from the pre-refresh lock state. It removes that saved set only after the source add succeeds. This order preserves source ownership long enough for safe cleanup and avoids deleting unrelated skills.

`tests/skills-external.bats:265-286` simulates the lock rewrite. The pre-add list owns `retired`; the post-add list reports it as unowned. The sync must still call `skills remove retired`.

A machine affected before this fix needs one direct removal for each already-orphaned directory. The lock no longer contains enough provenance for automatic source-safe cleanup.
