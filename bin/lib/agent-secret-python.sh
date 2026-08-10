# shellcheck shell=bash
# agent-secret-python.sh — shared python3 interpreter resolution for the
# agent-secret broker toolchain. Sourced by agent-secret-install and the
# installed agent-secret-{broker,proxy,ctl} wrappers so every consumer pins
# to the same interpreter agent-secret-install's services run under, instead
# of a bare PATH-resolved python3.

# agent_secret_python_path — print the resolved python3 interpreter path.
# Prefers /usr/bin/python3, falling back to the first python3 on PATH.
# Returns non-zero with no output if neither is found.
agent_secret_python_path() {
    if [[ -x /usr/bin/python3 ]]; then
        printf '%s\n' /usr/bin/python3
        return 0
    fi
    command -v python3 2>/dev/null
}
