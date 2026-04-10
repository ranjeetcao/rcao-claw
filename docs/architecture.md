# Architecture

## Overview

Zupee Claw is a secure, air-gapped AI development partner that runs inside Docker on a local machine. It combines local LLM inference via Ollama (Qwen 3.5) with delegated coding tasks through Claude Code, all connected via a locked-down SSH gateway. The system enforces 14 layers of defense-in-depth security to ensure the AI agent can only perform pre-approved actions on the host.

**Key separation:**
- `zupee-claw/` = Claw's home (configs, agent data, sessions, memory, scripts, Docker)
- `$WORKSPACE_DIR/` = actual development codebase (where Claude Code operates)

**Core design principles:**
- **Air-gapped inference** -- Ollama runs on an internal Docker network with zero internet access
- **Least privilege** -- every component has the minimum permissions needed
- **Defense in depth** -- 14 overlapping security layers (no single point of failure)
- **Full auditability** -- every command, allowed or denied, is logged with timestamps
- **Immutable agent identity** -- personality files are read-only; the agent cannot rewrite its own rules

## System Architecture Diagram

```
+------------------------------------------------------------------+
|  HOST MACHINE                                                     |
|                                                                   |
|  Browser --> http://localhost:3000                                 |
|                    |                                               |
|  +-----------------|-----------------------------------------+    |
|  |  DOCKER         |                                         |    |
|  |                 v                                         |    |
|  |  +-------------------+   isolated    +----------------+   |    |
|  |  |   Claw Gateway    |<------------>|    Ollama       |   |    |
|  |  |   (zupee-claw)    |  (internal)  |  (zupee-ollama) |   |    |
|  |  |   Web UI :3000    |              |  Qwen 3.5 LLM   |   |    |
|  |  +--------+----------+              +----------------+   |    |
|  |           |       |                                       |    |
|  |    squid-internal  |  host-access                         |    |
|  |           |        |  (internal)                          |    |
|  |           v        |                                      |    |
|  |  +----------------+|                                      |    |
|  |  |  Squid Proxy   ||                                      |    |
|  |  | (zupee-squid)  ||                                      |    |
|  |  |  ACL: Slack    ||                                      |    |
|  |  |  only (.slack  ||                                      |    |
|  |  |   .com:443)    ||                                      |    |
|  |  +-------+--------+|                                      |    |
|  |          |          |                                      |    |
|  |   squid-egress      |                                     |    |
|  |   (internet)        |                                     |    |
|  |          |          |                                      |    |
|  +----------|----------|-------------------------------------+    |
|             |          |                                          |
|             v          | SSH (host.docker.internal:22)            |
|        Slack API       | ForceCommand = ssh-gateway.sh            |
|        (*.slack.com)   |                                          |
|                        v                                          |
|  +----------------------------------------------------------+    |
|  |  openclaw-bot user (restricted shell, no sudo)            |    |
|  |                                                           |    |
|  |  ssh-gateway.sh --> allowed-commands.conf                 |    |
|  |    |                                                      |    |
|  |    +-- service-status.sh   (check health)                 |    |
|  |    +-- git-status.sh       (git status on repo)           |    |
|  |    +-- git-pull.sh         (git pull --rebase)            |    |
|  |    +-- run-tests.sh        (npm test on repo)             |    |
|  |    +-- run-claude.sh       (locked-down Claude Code)      |    |
|  |          |                                                |    |
|  |          v                                                |    |
|  |        Claude Code (25 turns, $10 cap)                    |    |
|  |          operates on: $WORKSPACE_DIR/$REPO                |    |
|  +----------------------------------------------------------+    |
+------------------------------------------------------------------+
```

## Data Flow

### Primary Flow: User Interaction

```
User (browser)
  |
  v
localhost:3000 (Claw Web UI, bound to 127.0.0.1 only)
  |
  v
Claw Gateway (Docker) --inference--> Ollama LLM (Docker, isolated network)
  |
  | (when host action is needed)
  v
SSH --> ssh-gateway.sh --> allowed-commands.conf
  |
  +-- service-status.sh    -> system health, available repos, disk usage
  +-- git-status.sh        -> git status on $WORKSPACE_DIR/$REPO
  +-- git-pull.sh          -> git pull --rebase on current branch
  +-- run-tests.sh         -> npm test (with optional args after --)
  +-- run-claude.sh        -> Claude Code (locked down)
        |
        v
      claude -p "..." --permission-mode dontAsk \
        --allowedTools ... --disallowedTools ... \
        --max-turns 25 --max-budget-usd 10.00
        |
        v
      $WORKSPACE_DIR/$REPO  (Read, Edit, Write, git, npm test)
```

### Slack Communication Flow

```
Claw Gateway (Socket Mode WebSocket)
  |
  | HTTPS_PROXY=http://squid:3128
  v
Squid Proxy (ACL: *.slack.com, *.slack-edge.com, port 443 only)
  |
  v (squid-egress network, internet access)
Slack API (REST + WebSocket)
```

### Model Download Flow (one-time, during setup)

```
setup.sh temporarily connects Ollama to squid-egress network
  |
  v
Ollama --> Squid Proxy --> Internet (model registry)
  |
  v
setup.sh disconnects Ollama from squid-egress
(Ollama returns to air-gapped state)
```

## Network Architecture

Four custom Docker bridge networks provide strict isolation:

| Network | `internal` | Services | Purpose |
|---------|-----------|----------|---------|
| `isolated` | `true` | ollama, openclaw | LLM inference traffic only. No internet. |
| `host-access` | `true` | openclaw | SSH from container to host via `host.docker.internal`. No internet. |
| `squid-internal` | `true` | openclaw, squid | HTTP proxy traffic (openclaw -> squid). No internet. |
| `web-access` | `false` | openclaw | Web UI port publishing to `127.0.0.1:3000`. |
| `squid-egress` | `false` | squid | Squid outbound to internet (Slack API only via ACL). |

**Key isolation properties:**
- Ollama has **zero internet access** -- it only joins `isolated`
- Openclaw reaches the internet **only through Squid** (which only allows Slack domains)
- Host access is via SSH only, through a ForceCommand gateway
- Web UI is bound to `127.0.0.1` -- not accessible from the local network

## Docker Services

| Service | Container | Image | Resources | Networks | Health Check |
|---------|-----------|-------|-----------|----------|-------------|
| `openclaw` | `zupee-claw` | Built from `docker/Dockerfile` (node:22-slim) | `${CLAW_MEM:-1G}`, `${CLAW_CPUS:-1}` | isolated, host-access, squid-internal, web-access | `curl -sf http://localhost:3000/health` |
| `ollama` | `zupee-ollama` | `ollama/ollama:0.20.3` | `${OLLAMA_MEM:-4G}`, `${OLLAMA_CPUS:-1.5}` | isolated | `ollama list` |
| `squid` | `zupee-squid` | `ubuntu/squid:latest` | 256M, 0.5 CPU | squid-internal, squid-egress | TCP check on :3128 |

**Startup order:** Ollama and Squid start first; Openclaw waits for both to report healthy.

**Resource allocation** (calculated by `setup.sh`):
- Ollama: 50% CPUs, 50% RAM (LLM inference is memory-hungry)
- Claw: 25% CPUs, 20% RAM
- Reserved: 30% for host OS and Squid proxy

## Volume Mounts

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `openclaw-home/` | `/home/openclaw/.openclaw` | `rw` | Agent config, runtime data, memory, sessions |
| `bin/` | `/openclaw/bin` | `ro` | Whitelisted gateway scripts (immutable) |
| `config/openclaw-docker-key` | `/openclaw/.ssh/id_ed25519` | `ro` | SSH private key for host access |
| `logs/` | `/openclaw/logs` | `rw` | Audit trail (gateway, claude, openclaw logs) |
| `docker/squid.conf` | `/etc/squid/squid.conf` | `ro` | Squid proxy configuration |
| `logs/squid/` | `/var/log/squid` | `rw` | Squid access and cache logs |
| `ollama-models` (named) | `/root/.ollama` | `rw` | Persistent LLM model storage |

## Directory Structure

```
zupee-claw/
├── .env.example                        # Environment config template
├── .env                                # Local config (gitignored)
├── setup.sh                            # End-to-end provisioning (7 phases)
├── cleanup.sh                          # Full teardown with confirmations
├── CLAUDE.md                           # Claude Code project guide
├── README.md                           # Quickstart and usage
├── CONTRIBUTING.md                     # Development and PR guidelines
├── CODE_OF_CONDUCT.md                  # Contributor Covenant v2.1
│
├── bin/                                # Whitelisted scripts (mounted :ro)
│   ├── allowed-commands.conf           # Command allowlist (literal match)
│   ├── ssh-gateway.sh                  # SSH ForceCommand entry point
│   ├── workspace-env.sh                # Shared workspace/env resolver
│   ├── run-claude.sh                   # Claude Code launcher (locked down)
│   ├── git-status.sh                   # git status on workspace repo
│   ├── git-pull.sh                     # git pull --rebase on current branch
│   ├── run-tests.sh                    # npm test with optional args
│   └── service-status.sh              # System health + available repos
│
├── config/
│   ├── claude-settings.json            # Claude Code deny rules (persistent)
│   ├── sshd_openclaw.conf              # SSH daemon hardening (Match User)
│   ├── openclaw-docker-key             # Ed25519 private key (generated)
│   ├── openclaw-docker-key.pub         # Ed25519 public key (generated)
│   └── authorized_keys                 # ForceCommand-restricted key template
│
├── openclaw-home/                      # Maps to ~/.openclaw inside container
│   ├── openclaw.json                   # Gateway config (mode, port, models)
│   ├── agents/main/sessions/           # Session transcripts (JSONL)
│   ├── credentials/                    # OAuth tokens, API keys (host-protected)
│   ├── skills/                         # Shared managed skills
│   └── workspace/                      # Agent personality & memory
│       ├── AGENTS.md                   # Operating instructions & workflow
│       ├── SOUL.md                     # Persona, tone, personality
│       ├── USER.md                     # User profile & preferences
│       ├── IDENTITY.md                 # Agent name & identity
│       ├── TOOLS.md                    # Available tools reference
│       ├── MEMORY.md                   # Long-term memory index (runtime)
│       ├── memory/                     # Daily memory logs (runtime)
│       └── skills/                     # Workspace-specific skills
│
├── docker/
│   ├── Dockerfile                      # node:22-slim + openssh-client + curl
│   ├── docker-compose.yml              # 3 services, 5 networks
│   ├── entrypoint.sh                   # SSH setup, readiness wait, gateway start
│   └── squid.conf                      # Squid ACL (Slack domains only)
│
├── docs/
│   ├── architecture.md                 # This file
│   ├── components.md                   # Detailed component reference
│   ├── security-model.md               # Security layers & threat model
│   ├── setup-and-operations.md         # Installation & operations guide
│   └── slack-integration.md            # Slack Socket Mode setup
│
├── .github/
│   ├── workflows/lint.yml              # CI: ShellCheck, YAML lint, JSON validation
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md               # Bug report template
│   │   └── feature_request.md          # Feature request template
│   └── PULL_REQUEST_TEMPLATE.md        # PR template with testing checklist
│
└── logs/                               # Audit logs (gitignored, mounted :rw)
    ├── gateway.log                     # SSH command log (all allowed/denied)
    ├── claude.log                      # Claude Code execution log
    ├── openclaw.log                    # Gateway runtime log
    └── squid/                          # Squid proxy access/cache logs
```

## Agent Workspace Files

These files define the agent's personality, instructions, and runtime state. They are loaded at every session start.

| File | Purpose | Ownership | Mutable |
|------|---------|-----------|---------|
| `SOUL.md` | Persona, tone, personality traits | Host user (read-only to container) | No |
| `AGENTS.md` | Operating instructions, 7-step workflow | Host user (read-only to container) | No |
| `USER.md` | User profile, preferences, communication style | Host user (read-only to container) | No |
| `IDENTITY.md` | Agent name, vibe | Host user (read-only to container) | No |
| `TOOLS.md` | Available tools, allowed/blocked lists, Slack details | Host user (read-only to container) | No |
| `MEMORY.md` | Long-term memory index | Container (UID 1001) | Yes |
| `memory/*.md` | Daily memory logs | Container (UID 1001) | Yes |
| `openclaw.json` | Gateway config (mode, models, auth token) | Container (UID 1001) | Yes |

**Immutability guarantee:** Personality files (SOUL, AGENTS, USER, IDENTITY, TOOLS) are owned by the host user and set to `chmod 444` by the entrypoint script. The container cannot modify them.

## Configuration

All user configuration is managed through `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_VERSION` | `2026.4.2` | Pinned Claw gateway version |
| `REPO` | `my-project` | Default repository name under `$WORKSPACE_DIR/` |
| `WORKSPACE_DIR` | `~/workspace` | Root directory where dev repos live |
| `OLLAMA_MODEL` | `gemma4:e2b` | Ollama model for local inference |
| `SLACK_BOT_TOKEN` | (unset) | Bot User OAuth Token for Slack (`xoxb-...`) |
| `SLACK_APP_TOKEN` | (unset) | App-Level Token for Socket Mode (`xapp-...`) |

Resource limits are auto-calculated by `setup.sh` based on system hardware and can be overridden:

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_MEM` | 50% system RAM | Ollama memory limit |
| `OLLAMA_CPUS` | 50% system CPUs | Ollama CPU limit |
| `CLAW_MEM` | 20% system RAM | Claw gateway memory limit |
| `CLAW_CPUS` | 25% system CPUs | Claw gateway CPU limit |

## Host Commands (via SSH Gateway)

| Command | Script | Purpose |
|---------|--------|---------|
| `service-status` | `bin/service-status.sh` | System config, available repos, disk usage |
| `git-status [repo]` | `bin/git-status.sh` | Git working tree status |
| `git-pull [repo]` | `bin/git-pull.sh` | Git pull with rebase on current branch |
| `run-tests [repo] [-- args]` | `bin/run-tests.sh` | Run npm test suite with optional arguments |
| `run-claude <prompt> [repo]` | `bin/run-claude.sh` | Coding tasks via Claude Code (25 turns, $10 cap) |

Default repo comes from `REPO` in `.env`. All commands accept optional `[repo]` override.

**Adding a new command:**
1. Create `bin/<name>.sh` with `set -euo pipefail` at the top
2. Source `workspace-env.sh` for workspace resolution
3. Add `<name>` to `bin/allowed-commands.conf`
4. Test via SSH to confirm the gateway routes it correctly

## Security Overview

The system implements 14 layers of defense-in-depth security. See [security-model.md](security-model.md) for the full breakdown including threat model and mitigations.

**Summary of layers:**

| # | Layer | Blocks |
|---|-------|--------|
| 1 | Docker process isolation | Direct host access |
| 2 | 127.0.0.1 port binding | Network exposure |
| 3 | SSH ForceCommand | Arbitrary command execution |
| 4 | Command allowlist (literal match) | Unapproved scripts |
| 5 | Input validation (metacharacters, traversal) | Injection attacks |
| 6 | Rate limiting (30/min) | Brute force / abuse |
| 7 | Claude `--permission-mode dontAsk` | Unapproved tool usage |
| 8 | Claude `--disallowedTools` blacklist | Dangerous tools (ssh, curl, sudo, etc.) |
| 9 | Claude `--max-turns 25` | Runaway agent loops |
| 10 | Claude `--max-budget-usd 10` | API cost overruns |
| 11 | `.claude/settings.json` deny rules | Flag bypass attempts |
| 12 | Restricted shell (`rbash`/`false`) | Shell escapes |
| 13 | Read-only volume mounts | Script/config tampering |
| 14 | Squid ACL proxy | Unauthorized internet access |

## CI/CD

GitHub Actions workflow (`.github/workflows/lint.yml`) runs on push to `main` and all PRs:

| Job | Tool | What it validates |
|-----|------|------------------|
| ShellCheck | `shellcheck` | All `.sh` files in `bin/`, `setup.sh`, `cleanup.sh` |
| YAML Lint | `yamllint` | `docker/docker-compose.yml` |
| JSON Validation | Python `json` module | All `.json` files (excluding `.git/`) |

## Verification Checklist

After running `setup.sh`, verify the deployment:

```bash
# Claw web UI accessible?
curl -s http://localhost:3000/health

# Ollama responding?
docker compose -f docker/docker-compose.yml exec ollama ollama list

# SSH gateway works for allowed commands?
docker compose -f docker/docker-compose.yml exec openclaw ssh -i /openclaw/.ssh/id_ed25519 \
  openclaw-bot@host.docker.internal "service-status"

# Blocked command rejected?
docker compose -f docker/docker-compose.yml exec openclaw ssh -i /openclaw/.ssh/id_ed25519 \
  openclaw-bot@host.docker.internal "rm -rf /"
# Should see: DENIED in logs/gateway.log

# Rate limiting active?
# 31st command within 60s should be denied

# Logs flowing?
tail -f logs/gateway.log
tail -f logs/claude.log
```

- [ ] Claw web UI accessible at localhost:3000
- [ ] Ollama model responding
- [ ] SSH from container to host works for allowed commands
- [ ] SSH gateway blocks non-whitelisted commands
- [ ] SSH gateway blocks path traversal attempts
- [ ] SSH gateway blocks shell metacharacters
- [ ] Rate limiting enforced at 30 commands/min
- [ ] `run-claude.sh` operates on `$WORKSPACE_DIR` only
- [ ] Claude Code cannot use ssh, curl, wget, sudo, docker
- [ ] Claude Code cannot use `rm -rf`, `node -e`, `npx`
- [ ] Claude Code cannot access WebFetch/WebSearch
- [ ] All actions logged to `logs/` with ISO timestamps
- [ ] Container restart preserves agent data (volumes)
- [ ] Web UI not accessible from other machines (127.0.0.1 bind)
- [ ] Squid only allows `*.slack.com` and `*.slack-edge.com`
- [ ] Ollama has zero internet access
