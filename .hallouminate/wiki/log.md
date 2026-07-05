# Ingest Log

## Log

2026-07-01 · 0dc5b5d98eee412c · new-page · operations/claude-dotfiles-ownership.md · Captured Claude Code dotfiles ownership split, settings merge policy, and destructive cleanup rule.
2026-07-01 · 0dc5b5d98eee412c · merged · operations/sync-and-chezmoi.md · Replaced stale create_settings summary with modify_settings authoritative/preserved/unknown-key policy.
2026-07-01 · 0dc5b5d98eee412c · merged · harnesses/claude.md · Updated Claude settings/config row to point at current chezmoi modify_settings ownership.
2026-07-01 · 0dc5b5d98eee412c · merged · architecture/config-drift.md · Updated settings drift model for repo-owned vs ap-managed/live settings.

2026-07-01 · a89d382fedaf2fa3 · merged · operations/claude-dotfiles-ownership.md · Added Claude+chezmoi destructive-management policy: CLI uninstall/remove for runtime objects, modify_ for partial settings ownership, exact/remove only repo-owned paths.

2026-07-03 · claudeplugings · merged · operations/claude-dotfiles-ownership.md, architecture/cross-harness-plugins.md · Bridged native-claude plugins (milknado, hallouminate) into the chezmoi-authoritative pipeline: modify_settings.json overlays enabledPlugins/extraKnownMarketplaces from agents/plugins/registry.yaml; run_onchange + claude-plugin-reconcile.sh prime/prune the CLI marketplace index and installed_plugins.json (manifest-owned only). Corrected the stale "preserved from the live file / reasserted by ap" settings-merge bullet; noted the isolated-only gate on_render_native_plugins.
