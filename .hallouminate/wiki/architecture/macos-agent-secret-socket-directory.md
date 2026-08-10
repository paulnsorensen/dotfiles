# macOS agent-secret socket directory

`/var/run/dotfiles-agent-secrets` is volatile on macOS. LaunchDaemons therefore recreate it before the broker validates and binds its request/control sockets; otherwise launchd repeatedly exits with `socket path parent is not a directory` and Context7/Tavily MCP initialization closes.[^1]

The `--ensure-socket-parent` broker mode accepts only the fixed `SOCKET_ROOT`, requires root, refuses unsafe ownership or symlinks, assigns the requester’s primary group and restores mode `0710`. It is emitted only by the macOS launchd template; systemd already supplies the directory with `RuntimeDirectory`.[^2]

After deploying a change to the root-owned broker runtime, reprovision via `bin/vault-provision --request-user <daily-user> --operator-user root` in an interactive terminal so `sudo` can authenticate. This preserves the service-owned credential boundary.[^3]

[^1]: scripts/agent-secret-broker.py:215-234; services/agent-secret/com.dotfiles.agent-secret.plist:9-24
[^2]: services/agent-secret/agent-secret-broker@.service:11-14
[^3]: bin/vault-provision:72-87; architecture/mcp-secret-handling.md
