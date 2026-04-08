# Security Hardening

Comprehensive reference for all 11 protection layers in the Zupee Claw stack.

## The 11 Security Layers

### Layer 1 — Docker Isolation

Process and filesystem isolation via containers. The AI agent runs inside a container with no direct host access except through explicitly mounted volumes and the SSH gateway.

### Layer 2 — Localhost Binding

The web UI is bound to `127.0.0.1:3000`. This ensures the service is only accessible from the local machine. Never expose on `0.0.0.0`, which would make it reachable from the network.

### Layer 3 — SSH ForceCommand

All SSH sessions into the container are forced through `ssh-gateway.sh` via the `ForceCommand` directive in sshd config. No interactive shell is possible — every connection is routed through the gateway script.

### Layer 4 — Command Allowlist

`allowed-commands.conf` contains exact command names (one per line). The gateway resolves `<name>` to `bin/<name>.sh` and executes it. No glob patterns, no path components, no regex — only literal name matches.

### Layer 5 — Input Validation

All scripts reject dangerous input patterns:

- Shell metacharacters: ``; | & $ ` \ ( ) { } < >``
- Path traversal sequences: `..`
- Absolute paths in user-provided arguments
- Excessively long inputs (prompt limit: 8000 characters)

### Layer 6 — Claude Tool Whitelist

Claude Code runs with `--permission-mode dontAsk` and an explicit `--allowedTools` list. Only safe file operations (`Read`, `Edit`, `Write`, `Glob`, `Grep`) and controlled `git`/`npm` commands are permitted.

### Layer 7 — Claude Tool Blacklist

`--disallowedTools` explicitly blocks dangerous tool categories:

- **Network access**: `curl`, `wget`, `ssh`
- **System commands**: `sudo`, `docker`, `mount`
- **Interpreters**: `python`, `ruby`, `perl`
- **Shell escapes**: `bash -c`, `sh -c`, `eval`, `exec`
- **Bulk delete**: `rm -rf`, `rm -r`
- **Destructive git**: `push`, `rebase`, `reset`, `merge`

### Layer 8 — Execution Limits

`--max-turns 25` prevents runaway loops where the agent keeps executing without producing useful output.

### Layer 9 — Budget Cap

`--max-budget-usd 10.00` prevents cost overruns. The agent stops when the budget is exhausted.

### Layer 10 — Restricted Shell

The `openclaw-bot` user has `rbash` (on Linux) or `/usr/bin/false` (on macOS) as its login shell. Even if an attacker bypasses ForceCommand, they cannot get a full interactive shell.

### Layer 11 — Read-Only Mounts

`bin/` is mounted `:ro` in the container. The agent cannot modify its own gateway scripts, allowlist, or execution infrastructure. Config files are also mounted read-only.

## Hardening Checklist

Run through this checklist before any release or deployment:

- [ ] All Docker networks have `internal: true`
- [ ] Port binding is `127.0.0.1:3000:3000` (not `0.0.0.0`)
- [ ] No `privileged: true` anywhere in docker-compose.yml
- [ ] SSH `ForceCommand` points to `ssh-gateway.sh`
- [ ] `allowed-commands.conf` contains no dangerous commands
- [ ] `claude-settings.json` deny list blocks all escape vectors
- [ ] `run-claude.sh` flags match `claude-settings.json` deny rules
- [ ] Resource limits are set on all containers
- [ ] Healthchecks are configured for all services
- [ ] SSH key permissions are `600`
- [ ] No secrets committed to the repository
