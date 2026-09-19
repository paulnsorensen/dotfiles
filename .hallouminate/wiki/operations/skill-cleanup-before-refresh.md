# Remove retired skills before refresh

`install-external.sh` must snapshot retired source-owned skills before `npx skills add` refreshes the source.

The `skills` CLI rewrites `~/.agents/.skill-lock.json` during an add. When an upstream skill disappears, this rewrite removes its source record but leaves its copied directory. A later `skills list --global --json` then reports the directory with `source: null`. Source-filtered cleanup cannot identify or remove it.

`chezmoi/lib/install-external.sh:216-245` now computes the stale set from the pre-refresh lock state. It removes that saved set only after the source add succeeds. This order preserves source ownership long enough for safe cleanup and avoids deleting unrelated skills.

`tests/skills-external.bats:265-286` simulates the lock rewrite. The pre-add list owns `retired`; the post-add list reports it as unowned. The sync must still call `skills remove retired`.

A machine affected before this fix needs one direct removal for each already-orphaned directory. The lock no longer contains enough provenance for automatic source-safe cleanup.

## Retired local skills need a manifest, not source-filtering

`install_local_tree` copies this repo's `skills/` tree into the shared
`~/.agents/skills` via `npx skills add`. The CLI never removes a name dropped
from that source, and source-filtered cleanup cannot help: local skills record
`source: null` in the lock, which also covers retired externals and other repos'
skills. So `reconcile_local_skills` (`chezmoi/lib/install-external.sh`) tracks the
exact set it installs in `~/.agents/skills/.dotfiles-local-managed` and prunes
only names it previously installed that the source no longer provides. Pre-fix
orphans that were never recorded in the manifest need one manual removal.
`tests/skills-external.bats` covers the drop, keep, foreign-preserve, and
first-run cases.
