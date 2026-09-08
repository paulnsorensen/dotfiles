#!/usr/bin/env bash
# Single source of truth for the agent-secret broker's runtime assets: each
# row is `source path relative to DOTFILES_DIR|installed filename|install mode`.
# Consumed by agent-secret-install (deploys the assets) and
# agent-secret-staleness.sh (detects drift against the deployed copies).

# shellcheck disable=SC2034 # consumed by scripts that source this file
AGENT_SECRET_RUNTIME_ASSETS='
bin/agent-secret-broker|agent-secret-broker|0755
bin/agent-secret-proxy|agent-secret-proxy|0755
bin/agent-secretctl|agent-secretctl|0755
bin/lib/agent-secret-python.sh|agent-secret-python.sh|0644
scripts/agent-secret-broker.py|agent-secret-broker.py|0755
'
