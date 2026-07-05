#!/usr/bin/env bash
# doc-drift routine — cloud environment setup script.
#
# Paste this into the Claude Code routine environment's "setup script" field
# (or point it at this committed copy). It runs once before the agent launches
# and the result is cached, so it does not re-run every firing. Custom base
# images aren't supported for cloud routines — a setup script is the sanctioned
# way to add tools the base image lacks.
#
# It installs only what the routine needs beyond the base image. The routine
# itself indexes + grounds the wiki (the repo checkout is present then).
set -euo pipefail

# gh: normally on the base image. Auth is the environment's native GitHub OAuth
# flow, NOT a token passed here. Install only if missing.
command -v gh >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y gh; }

# hallouminate: prebuilt binary via the cargo-dist installer — no Rust toolchain
# or build deps. Lets the routine ground the committed wiki for richer issues.
command -v hallouminate >/dev/null 2>&1 || \
    curl --proto '=https' --tlsv1.2 -LsSf \
      https://github.com/paulnsorensen/hallouminate/releases/latest/download/hallouminate-installer.sh | sh
