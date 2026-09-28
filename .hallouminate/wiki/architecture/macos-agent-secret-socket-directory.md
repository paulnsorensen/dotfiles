# macOS agent-secret socket directory

`/var/run/dotfiles-agent-secrets` is volatile on macOS. LaunchDaemons therefore recreate it before the broker validates and binds its request/control sockets; otherwise launchd repeatedly exits with `socket path parent is not a directory` and Context7/Tavily MCP initialization closes.[^1]

The `--ensure-socket-parent` broker mode accepts only the fixed `SOCKET_ROOT`, requires root, refuses unsafe ownership or symlinks, assigns the requester’s primary group and restores mode `0710`. It is emitted only by the macOS launchd template; systemd already supplies the directory with `RuntimeDirectory`.[^2]

After deploying a change to the root-owned broker runtime, reprovision via `bin/vault-provision --request-user <daily-user> --operator-user root` in an interactive terminal so `sudo` can authenticate. This preserves the service-owned credential boundary.[^3]

## Broker lifetime and socket ownership

A broker refuses a socket that a live broker still serves. Before it unlinks an existing socket, it connects to it. Only a refused or vanished connection proves that the socket is stale. Without this guard, a second broker takes over a live socket, and the first broker runs with nothing to serve.[^4]

A broker exits when its parent process exits. launchd and systemd start the installed broker under PID 1, so its parent never changes. Other callers, such as a Bats run from a worktree, own the broker's lifetime. Without this rule, an aborted test run leaves brokers alive after its worktree is gone.[^5]

On SIGTERM, a broker closes its sockets and then dies by the signal, not with exit 0. launchd restarts a `KeepAlive` job only after an unsuccessful exit. An unprivileged broker removes both socket files. The installed broker drops root after it binds, so it cannot delete them from the root-owned `0710` directory. The next start finds them stale and replaces them.[^5]

`dots doctor` reports broker processes whose script path is missing and brokers that share one socket. It does not compare the installed broker with the repository copy; #643 owns that check.[^6]

[^1]: scripts/agent-secret-broker.py:215-234; services/agent-secret/com.dotfiles.agent-secret.plist:9-24
[^2]: services/agent-secret/agent-secret-broker@.service:11-14
[^3]: bin/vault-provision:72-87; architecture/mcp-secret-handling.md
[^4]: scripts/agent-secret-broker.py:761-796; tests/agent-secret-broker.bats:531-548
[^5]: scripts/agent-secret-broker.py:927-961; tests/agent-secret-broker.bats:568-596
[^6]: bin/lib/agent-secret-doctor.sh:18-56; tests/agent-secret-doctor.bats

## ProcessType must stay `Standard` (2026-09-28)

The launchd template shipped `ProcessType: Background`. launchd runs a Background daemon and every child it spawns at the lowest CPU and I/O class (`ps -o pri` shows 4, against 31 for a normal process). The broker spawns `npx ... context7-mcp` per MCP session, so on a loaded Mac the upstream needed 10-23 s to answer `initialize`; the same command at normal priority took 2-3 s. Claude Code aborts an MCP connect after 30 s, so context7 and tavily reported `CONNECT_TIMEOUT`. The template now sets `Standard`, and `tests/agent-secret-install.bats` asserts it. Deploying the change needs the reprovision step above.
