status: ok
next: done
artifact: .cheese/cheese-factory/ap-chezmoi-compiler/wiring/phase4.md

Phase 4 wiring completed in one commit: live deployment now flows through `dots sync` → `ap fetch-sources live` → `ap compile live --baseline <scratch> --out <cache>` → drift gate → `ap apply-compiled <manifest>`.

Changed wiring files:

- `agent-profile/agent_profile/parse.py`
- `agent-profile/agent_profile/cli.py`
- `profiles/live/profile.yaml`
- `profiles/global/profile.yaml`
- `profiles/opencode-global/profile.yaml`
- `chezmoi/lib/install-base-profile.sh`
- `chezmoi/.chezmoiscripts/run_onchange_after_install-base-profile.sh.tmpl`
- `bin/dots`
- `tests/install-base-profile.bats`
- `tests/config-validation.bats`

Verification:

- `uv run --project agent-profile pytest agent-profile/tests -q` — 870 passed
- `dots test` — 932 passed
