# Security Model

Zupee Claw implements a defense-in-depth security architecture with 14 overlapping layers. No single layer is the sole line of defense -- each layer assumes the others may be compromised.

## Design Principles

- **Least privilege** -- every component has the minimum permissions needed to function
- **Defense in depth** -- 14 layers; compromise of any single layer does not grant full access
- **Fail closed** -- if validation fails at any stage, the request is denied
- **Immutable identity** -- the agent cannot modify its own rules, personality, or scripts
- **Full auditability** -- every action (allowed or denied) is logged with timestamps and PIDs
- **No trust boundaries within the chain** -- each layer validates independently

## Security Layers

### Layer 1: Docker Process Isolation

**What it does:** Runs Claw and Ollama in separate containers with process and filesystem isolation.

**Protects against:** Direct host filesystem access, process interference, environment variable leakage between services.

**Implementation:**
- `docker/Dockerfile` -- builds from `node:22-slim`, creates non-root user (UID 1001)
- `docker/docker-compose.yml` -- defines separate services with independent resource limits
- No `privileged: true`, no `cap_add`, no `network_mode: host`

### Layer 2: Localhost Port Binding

**What it does:** Binds the Web UI exclusively to `127.0.0.1:3000`.

**Protects against:** Network exposure to other machines on the LAN or internet.

**Implementation:** `docker-compose.yml` port binding: `"127.0.0.1:3000:3000"`

**Note:** Inside the container, the gateway binds to `0.0.0.0` -- this is safe because Docker's port mapping restricts external access to localhost only.

### Layer 3: SSH ForceCommand

**What it does:** Intercepts every SSH connection to the `openclaw-bot` user and routes it through `ssh-gateway.sh`.

**Protects against:** Interactive shell access, arbitrary command execution on the host.

**Implementation:**
- `config/sshd_openclaw.conf` -- `ForceCommand /path/to/ssh-gateway.sh`
- `config/authorized_keys` -- `command="/path/to/ssh-gateway.sh"` on the key line
- Both `authorized_keys` and `sshd_config` enforce ForceCommand (belt and suspenders)

**Additional SSH restrictions:**
- `PasswordAuthentication no` -- key-only auth
- `AllowTcpForwarding no` -- no SSH tunnels
- `X11Forwarding no` -- no display forwarding
- `PermitTunnel no` -- no VPN tunnels
- `AllowAgentForwarding no` -- no agent hijacking
- `no-pty` on authorized_keys -- no pseudo-terminal

### Layer 4: Command Allowlist

**What it does:** Only commands listed in `allowed-commands.conf` can be executed. Uses `grep -Fqx` for literal whole-line matching.

**Protects against:** Execution of any script or binary not explicitly approved.

**Implementation:** `bin/ssh-gateway.sh` line ~80:
```bash
grep -Fqx "$CMD_NAME" "$ALLOWLIST"
```
- `-F` = fixed string (no regex)
- `-q` = quiet
- `-x` = whole line match

**Current allowlist:** `git-status`, `git-pull`, `run-tests`, `run-claude`, `service-status`

### Layer 5: Input Validation

**What it does:** Validates all inputs (command names and arguments) before any execution.

**Protects against:** Command injection, path traversal, shell metacharacter exploitation.

**Blocked patterns:**
| Pattern | Example Attack | Blocked By |
|---------|---------------|-----------|
| `..` in command name | `../../etc/passwd` | Path traversal check |
| `/` in command name | `/bin/sh` | Absolute path check |
| `;` in arguments | `repo; rm -rf /` | Metacharacter regex |
| `\|` in arguments | `repo \| cat /etc/shadow` | Metacharacter regex |
| `$()` in arguments | `$(curl evil.com)` | Metacharacter regex |
| `` ` `` in arguments | `` `curl evil.com` `` | Metacharacter regex |

**Full metacharacter blocklist:** `` ; | & $ ` \ ( ) { } < > ``

**Applied in:** `ssh-gateway.sh` (command + args), `workspace-env.sh` (repo name), `run-tests.sh` (test args)

### Layer 6: Rate Limiting

**What it does:** Limits SSH gateway to 30 commands per 60-second sliding window.

**Protects against:** Brute-force attempts, denial of service, rapid-fire probing.

**Implementation:** Token bucket algorithm with `flock` for atomic file access. Rate limit file at `$HOME/openclaw/.rate-limit`. Exceeded limits result in DENIED log entries and non-zero exit codes.

### Layer 7: Claude Tool Whitelist

**What it does:** `--permission-mode dontAsk` ensures Claude Code can only use explicitly listed tools.

**Protects against:** Use of any tool not in the approved list (fail-closed model).

**Allowed tools (27 total):**
- File I/O: Read, Edit, Write, Glob, Grep
- Package management: `npm test`, `npm run`, `npm install`, `npm ci`
- Git (safe): diff, log, status, show, add, commit, branch, checkout, stash, remote
- Node.js (safe paths): `node src/*`, `node scripts/*`, `node dist/*`
- Utilities: ls, mkdir, rm (single files by extension), head, tail, wc, sort, which

### Layer 8: Claude Tool Blacklist

**What it does:** `--disallowedTools` explicitly blocks dangerous tools even if somehow added to the whitelist.

**Protects against:** Dangerous tool usage (network access, system commands, destructive operations).

**Blocked categories (50+ tools):**

| Category | Blocked Tools |
|----------|--------------|
| Network | `curl`, `wget`, `ssh`, `WebFetch`, `WebSearch` |
| System | `sudo`, `su`, `chmod`, `chown`, `mount`, `umount` |
| Interpreters | `python`, `python3`, `ruby`, `perl`, `awk`, `sed` |
| Shell escape | `bash -c`, `sh -c`, `eval`, `exec` |
| Bulk delete | `rm -rf`, `rm -r` |
| Destructive git | `push`, `rebase`, `reset`, `merge`, `config` |
| Package managers | `pip`, `pip3`, `npx` |
| Sandbox escape | `find`, `xargs`, `tee`, `ln` |
| Process control | `kill`, `pkill`, `nohup`, `crontab` |
| Arbitrary exec | `node -e`, `node --eval` |

### Layer 9: Execution Turn Limit

**What it does:** `--max-turns 25` limits Claude Code to 25 API round-trips per invocation.

**Protects against:** Runaway agent loops, infinite retry cycles.

### Layer 10: Budget Cap

**What it does:** `--max-budget-usd 10.00` caps API spending per Claude Code invocation.

**Protects against:** Cost overruns from expensive or repeated API calls.

**Hard limit:** Never raise above $50 (documented constraint in `claude-lockdown.md`).

### Layer 11: Persistent Deny Rules

**What it does:** `config/claude-settings.json` deployed to `$WORKSPACE_DIR/.claude/settings.json` provides persistent deny rules independent of CLI flags.

**Protects against:** Bypass attempts that might circumvent CLI flags but not file-based settings.

**Requirement:** Must stay in sync with `run-claude.sh` flags. Both must deny the same tools.

### Layer 12: Restricted Shell

**What it does:** The `openclaw-bot` host user has a restricted shell (`rbash` on Linux, `/usr/bin/false` on macOS).

**Protects against:** Shell escapes, pipe usage, redirect exploitation, PATH manipulation.

**`rbash` restrictions:** Cannot change PATH, cannot use pipes or redirects, cannot execute commands with `/`, cannot use `exec`, `set`, `unset`, `env`.

### Layer 13: Read-Only Volume Mounts

**What it does:** Scripts (`bin/`) and config files are mounted `:ro` into the container.

**Protects against:** Agent tampering with its own scripts, gateway code, or security configuration.

**Read-only mounts:**
- `bin/` -> `/openclaw/bin:ro` (gateway scripts)
- `config/openclaw-docker-key` -> `/openclaw/.ssh/id_ed25519:ro` (SSH key)
- `docker/squid.conf` -> `/etc/squid/squid.conf:ro` (proxy config)

**Additional protection:** Personality files (SOUL.md, AGENTS.md, etc.) are set to `chmod 444` by the entrypoint script and owned by the host user, not UID 1001.

### Layer 14: Squid ACL Proxy

**What it does:** All outbound internet traffic from the container must pass through Squid, which only allows HTTPS connections to `*.slack.com` and `*.slack-edge.com` on port 443.

**Protects against:** Data exfiltration, unauthorized API calls, downloading malicious payloads.

**Implementation:**
- `HTTP_PROXY` and `HTTPS_PROXY` environment variables route all traffic through Squid
- Squid ACL denies everything except whitelisted Slack domains
- Ollama does NOT join the squid network -- fully air-gapped
- `NO_PROXY=ollama,localhost,127.0.0.1,host.docker.internal` ensures internal traffic stays internal

## Network Isolation Matrix

| Service | isolated | host-access | squid-internal | web-access | squid-egress | Internet |
|---------|----------|-------------|----------------|------------|-------------|---------|
| openclaw | Yes | Yes | Yes | Yes | No | No (proxy only) |
| ollama | Yes | No | No | No | No | No (air-gapped) |
| squid | No | No | Yes | No | Yes | Slack domains only |

**Key properties:**
- Ollama has **zero** network connectivity beyond the `isolated` bridge
- Openclaw can reach the internet **only** through Squid (which restricts to Slack)
- Squid is the **only** service with external network access
- All internal networks have `internal: true` (Docker does not route to host network)

## Threat Model

| Threat | Attack Vector | Mitigation | Layer(s) |
|--------|--------------|-----------|----------|
| Interactive shell access | SSH connection without command | ForceCommand intercepts, empty command rejected | 3, 4 |
| Arbitrary command execution | SSH with unapproved command | Allowlist validation (literal match) | 4 |
| Command injection | Shell metacharacters in args | Regex validation blocks `` ; \| & $ ` \ ( ) { } < > `` | 5 |
| Path traversal | `../../etc/passwd` as command/arg | Blocks `..` and absolute paths | 5 |
| Code injection via .env | Malicious values in .env | `grep`+`cut` parsing (never `source .env`) | 5 |
| Repo directory escape | Crafted repo name to escape workspace | Path validation + directory existence check | 5 |
| Brute force / probing | Rapid-fire SSH commands | Rate limiting: 30 commands/60s | 6 |
| Unauthorized tool usage | Claude uses blocked tool | Tool whitelist + blacklist (double enforcement) | 7, 8 |
| Runaway agent loop | Claude runs indefinitely | 25-turn limit per invocation | 9 |
| API cost overrun | Expensive API calls | $10 budget cap per run | 10 |
| Setting bypass | Flags ignored/overridden | Persistent deny rules in settings.json | 11 |
| Shell escape | Exploit restricted shell | `rbash` (Linux) / `/usr/bin/false` (macOS) | 12 |
| Script tampering | Agent modifies gateway code | Read-only volume mounts | 13 |
| Identity rewrite | Agent modifies own persona | chmod 444 + host ownership on personality files | 13 |
| Data exfiltration | curl/wget to external server | Squid ACL blocks all non-Slack domains | 14 |
| Model poisoning | Download malicious model | Ollama air-gapped; model pull only during setup | 1, 14 |
| Network scanning | Container scans LAN | `internal: true` on all networks; no host network mode | 1, 14 |
| Privilege escalation | sudo/docker from agent | Blocked in tool blacklist; `openclaw-bot` has no sudo | 8, 12 |
| Log tampering | Agent modifies audit trail | Logs on host filesystem; sanitized (no newlines, no control chars) | 5 |
| SSH key compromise | Key stolen from container | Key mounted read-only; copied with 600 perms inside container | 13 |
| Container escape | Break out of Docker | No privileged mode, no cap_add, resource limits enforced | 1 |
| Prompt injection | Oversized or crafted prompt | 8000 character prompt limit in run-claude.sh | 5 |

## Audit Trail

Every action in the system is logged:

| Log File | What it Records | Format |
|----------|----------------|--------|
| `logs/gateway.log` | All SSH commands (ALLOWED and DENIED) | `[ISO8601] [PID] ALLOWED/DENIED: command` |
| `logs/claude.log` | Claude Code invocations (start, end, exit code) | `[ISO8601] START/END: dir, prompt prefix, exit code` |
| `logs/openclaw.log` | Claw gateway runtime output | Gateway stdout + stderr |
| `logs/squid/access.log` | All proxy requests (Slack API calls) | Standard Squid access log format |

**Log sanitization:** Gateway log messages have newlines removed and non-printable characters stripped to prevent log injection attacks.

## File Ownership Strategy

| Files | Owner | Why |
|-------|-------|-----|
| Personality files (SOUL.md, AGENTS.md, etc.) | Host user + chmod 444 | Immutable: agent cannot rewrite its own rules |
| Credentials directory | Host user + chmod 600 | Protected: agent can read but not modify |
| Gateway runtime dirs (agents, canvas, devices, etc.) | UID 1001 (container) | Writable: gateway needs atomic write access |
| Memory and skills | UID 1001 (container) | Writable: agent runtime data |
| Scripts (bin/) | Host user + mounted :ro | Immutable: scripts cannot be tampered with |
| Logs | UID 1001 / UID 13 (squid) | Writable: audit trail must be appendable |

## Hard Constraints (NEVER Violate)

These constraints are documented across multiple rule files and must never be relaxed:

| Constraint | Source |
|-----------|--------|
| Never remove `ssh`, `curl`, `sudo`, `docker` from deny list | `claude-lockdown.md` |
| Never raise budget cap above $50 | `claude-lockdown.md` |
| Never allow `WebFetch` or `WebSearch` tools | `claude-lockdown.md` |
| Never allow `node -e` or `npx` execution | `claude-lockdown.md` |
| Never add `privileged: true` to any service | `docker-security.md` |
| Never use `network_mode: host` | `docker-security.md` |
| Never remove `internal: true` from networks | `docker-security.md` |
| Never mount `/` or `/etc` from host | `docker-security.md` |
| Never add `cap_add` capabilities | `docker-security.md` |
| Never allow glob patterns in allowlist | `ssh-gateway.md` |
| Never skip input validation | `ssh-gateway.md` |
| Never disable logging | `ssh-gateway.md` |
| Never allow interactive shell access | `ssh-gateway.md` |
| Never use `source .env` | `shell-conventions.md` |
| Never bind to `0.0.0.0` at the Docker level | `docker-security.md` |

## Verification Commands

```bash
# SSH gateway allows approved commands
ssh openclaw-bot@host "service-status"

# SSH gateway blocks unapproved commands
ssh openclaw-bot@host "rm -rf /"
# Expected: DENIED in logs/gateway.log

# Path traversal blocked
ssh openclaw-bot@host "../../../etc/passwd"
# Expected: DENIED in logs/gateway.log

# Shell metacharacters blocked
ssh openclaw-bot@host "git-status; rm -rf /"
# Expected: DENIED in logs/gateway.log

# Rate limiting active
for i in {1..35}; do ssh openclaw-bot@host "service-status"; done
# Expected: commands 1-30 allowed, 31-35 denied

# Claude tool blacklist enforced
# From run-claude: bash -c, curl, ssh, sudo all blocked

# Squid allows only Slack
curl --proxy http://127.0.0.1:3128 https://slack.com/api/api.test  # Should succeed
curl --proxy http://127.0.0.1:3128 https://google.com              # Should return 403

# Audit logs flowing
tail -f logs/gateway.log
tail -f logs/claude.log
tail -f logs/squid/access.log

# Ollama air-gapped (should fail)
docker exec zupee-ollama curl -s https://google.com  # Should fail (no network)
```
