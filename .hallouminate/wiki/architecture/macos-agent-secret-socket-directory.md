# macOS agent-secret socket directory

`/var/run/dotfiles-agent-secrets` is volatile on macOS. LaunchDaemons therefore recreate it before the broker validates and binds its request/control sockets; otherwise launchd repeatedly exits with `socket path parent is not a directory` and Context7/Tavily MCP initialization closes.[^1]

The `--ensure-socket-parent` broker mode accepts only the fixed `SOCKET_ROOT`, requires root, refuses unsafe ownership or symlinks, assigns the requester’s primary group and restores mode `0710`. It is emitted only by the macOS launchd template; systemd already supplies the directory with `RuntimeDirectory`.[^2]

After deploying a change to the root-owned broker runtime, reprovision via `bin/vault-provision --request-user <daily-user> --operator-user root` in an interactive terminal so `sudo` can authenticate. This preserves the service-owned credential boundary.[^3]

## Broker lifetime and socket ownership

A broker refuses a socket that a live broker still serves. Before it unlinks an existing socket, it connects to it. Only a refused or vanished connection proves that the socket is stale. Before this guard, a second broker silently took over a live socket, and the first broker kept running with nothing to serve (#1100).[^4]

A broker exits when its parent process exits, and SIGTERM removes both sockets. launchd and systemd start the installed broker under PID 1, so its parent never changes. Other callers, such as a Bats run from a worktree, own the broker's lifetime. Aborted test runs used to leave brokers alive for weeks after their worktree was removed.[^5]

`dots doctor` reports broker processes whose script path is missing and brokers that share one socket.[^6]

[^1]: scripts/agent-secret-broker.py:215-234; services/agent-secret/com.dotfiles.agent-secret.plist:9-24
[^2]: services/agent-secret/agent-secret-broker@.service:11-14
[^3]: bin/vault-provision:72-87; architecture/mcp-secret-handling.md
[^4]: scripts/agent-secret-broker.py:761-796; tests/agent-secret-broker.bats "a second broker refuses a socket that a live broker still serves"
[^5]: scripts/agent-secret-broker.py:927-942; tests/agent-secret-broker.bats "a broker exits when the process that started it exits"
[^6]: bin/lib/agent-secret-doctor.sh; tests/agent-secret-doctor.bats
