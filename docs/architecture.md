# Architecture

## Overview

RCao Claw is a secure, air-gapped AI development partner. The Claw gateway runs inside Docker; Ollama runs either natively on the host (macOS, for Metal GPU acceleration) or as a sibling Docker container (Linux/CI). Local inference is combined with delegated coding tasks through Claude Code, all connected via a locked-down SSH gateway. The system enforces 14 layers of defense-in-depth security to ensure the AI agent can only perform pre-approved actions on the host.

**Key separation:**
- `rcao-claw/` = repo contents (scripts, configs, Docker, personality)
- `~/.openclaw/` = per-machine runtime state (managed by OpenClaw, not in repo)
- `$WORKSPACE/` = actual development codebase (where Claude Code operates)

**Core design principles:**
- **Air-gapped inference** -- Ollama runs on an internal Docker network with zero internet access
- **Least privilege** -- every component has the minimum permissions needed
- **Defense in depth** -- 14 overlapping security layers (no single point of failure)
- **Full auditability** -- every command, allowed or denied, is logged with timestamps
- **Immutable agent identity** -- personality files are read-only; the agent cannot rewrite its own rules

## System Architecture Diagram

```
+---------------------------------------------------------------------+
|  HOST MACHINE                                                        |
|                                                                      |
|  Browser --> http://127.0.0.1:3000                                   |
|                    |                                                 |
|  +-----------------|----------------------------------------------+  |
|  |  DOCKER         |                                              |  |
|  |                 v                                              |  |
|  |  +-------------------+     isolated                            |  |
|  |  |   Claw Gateway    |<----(internal, no internet)----+        |  |
|  |  |   (rcao-claw)     |                                |        |  |
|  |  |   Web UI :3000    |  docker mode only:             |        |  |
|  |  |   non-root 1001   |  +---------------------+       |        |  |
|  |  +--+--------+-------+  |     Ollama          |<------+        |  |
|  |     |        |          |   (rcao-ollama)     |                |  |
|  |     |        |          |   profile:          |                |  |
|  |     |        |          |   docker-ollama     |                |  |
|  |     |        |          +---------------------+                |  |
|  |     |        |                                                  |  |
|  |     |  host-access (internal)                                   |  |
|  |     |        |                                                  |  |
|  |     |  squid-internal (internal, no internet)                   |  |
|  |     v        |                                                  |  |
|  |  +---------+ +---------+  +---------+                           |  |
|  |  | Squid   |-| SearXNG |--| Valkey  |                           |  |
|  |  | Proxy   | | (search)|  | (cache) |                           |  |
|  |  | ACL     | +---------+  +---------+                           |  |
|  |  +----+----+                                                    |  |
|  |       |                                                         |  |
|  |   squid-egress (outbound)                                       |  |
|  +-------|-----------------|---------------------------------------+  |
|          |                 |                                          |
|          v                 | native mode (macOS default):             |
|    Internet (Slack         |   host.docker.internal:11434 --> Ollama  |
|    + whitelisted           |   (runs on host, Metal GPU)              |
|    search engines)         |                                          |
|                            | SSH to host (host.docker.internal:22)    |
|                            | ForceCommand = ssh-gateway.sh            |
|                            v                                          |
|  +----------------------------------------------------------------+  |
|  |  openclaw-bot user (rbash restricted shell, no sudo)            |  |
|  |                                                                 |  |
|  |  ssh-gateway.sh --> allowed-commands.conf (5 entries)           |  |
|  |    |                                                            |  |
|  |    +-- service-status.sh  (host health + available repos)       |  |
|  |    +-- git-status.sh      (git status on repo)                  |  |
|  |    +-- git-pull.sh        (git pull --rebase)                   |  |
|  |    +-- run-tests.sh       (npm test on repo)                    |  |
|  |    +-- run-claude.sh      (locked-down Claude Code)             |  |
|  |          |                                                      |  |
|  |          v                                                      |  |
|  |        Claude Code (25 turns, $10 cap)                          |  |
|  |          operates on: $WORKSPACE                                |  |
|  +----------------------------------------------------------------+  |
+---------------------------------------------------------------------+
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
Claw Gateway (Docker) --inference--> Ollama LLM
                                      native mode: host.docker.internal:11434 (host, Metal GPU)
                                      docker mode: ollama:11434 on `isolated` network
  |
  | (when host action is needed)
  v
SSH --> ssh-gateway.sh --> allowed-commands.conf
  |
  +-- service-status.sh    -> system health, available repos, disk usage
  +-- git-status.sh        -> git status on $WORKSPACE
  +-- git-pull.sh          -> git pull --rebase on current branch
  +-- run-tests.sh         -> npm test (with optional args after --)
  +-- run-claude.sh        -> Claude Code (locked down)
        |
        v
      claude -p "..." \
        --settings <generated claude-run-settings.json> \
        --append-system-prompt <personality: IDENTITY + SOUL + AGENTS> \
        --permission-mode dontAsk \
        --max-turns 25 --max-budget-usd 10.00
        |
        v
      $WORKSPACE  (Read, Edit, Write, git, npm test)
```

### Egress Flow (Slack + SearXNG web search)

```
Claw Gateway (Socket Mode WebSocket, SearXNG HTTP)
  |
  | HTTPS_PROXY=http://squid:3128 (CONNECT over port 443 only)
  v
Squid Proxy ACL allowlist:
  - Slack: *.slack.com, *.slack-edge.com
  - Search/dev: *.google.com, *.googleapis.com, duckduckgo.com, *.bing.com,
                api.github.com, *.stackoverflow.com, *.stackexchange.com,
                arxiv.org, *.wikipedia.org, registry.npmjs.org, pypi.org,
                hub.docker.com
  |
  v (squid-egress network, internet access)
Destination (any other domain is blocked)
```

All requests are HTTPS (CONNECT tunnel on port 443). Plain HTTP is denied. Unmatched domains return `403 Forbidden`.

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

Five custom Docker bridge networks provide strict isolation:

| Network | `internal` | Services | Purpose |
|---------|-----------|----------|---------|
| `isolated` | `true` | ollama, openclaw | LLM inference traffic only. No internet. |
| `host-access` | `true` | openclaw | SSH from container to host via `host.docker.internal`. No internet. |
| `squid-internal` | `true` | openclaw, searxng, valkey, squid | HTTP proxy traffic and SearXNG cache. No internet. |
| `web-access` | `false` | openclaw | Web UI port publishing to `127.0.0.1:3000`. |
| `squid-egress` | `false` | squid | Squid outbound to internet (Slack + whitelisted search engines via ACL). |

**Key isolation properties:**
- Ollama has **zero internet access** -- it only joins `isolated`
- Openclaw reaches the internet **only through Squid** (which only allows Slack + whitelisted search engine domains)
- SearXNG and Valkey are fully internal (no internet); SearXNG only egresses through Squid
- Host access is via SSH only, through a ForceCommand gateway
- Web UI is bound to `127.0.0.1` -- not accessible from the local network

## Docker Services

| Service | Container | Image | Resources | Networks | Health Check |
|---------|-----------|-------|-----------|----------|-------------|
| `openclaw` | `rcao-claw` | Built from `docker/Dockerfile` (node:22-slim) | `${CLAW_MEM:-1G}`, `${CLAW_CPUS:-1}` | isolated, host-access, squid-internal, web-access | `curl -sf http://localhost:3000/health` |
| `ollama` | `rcao-ollama` | `ollama/ollama:0.20.3` (profile `docker-ollama`) | `${OLLAMA_MEM:-4G}`, `${OLLAMA_CPUS:-1.5}` | isolated | `ollama list` |
| `searxng` | `rcao-searxng` | `searxng/searxng:2026.3.28-cf5389afd` | 512M, 0.5 CPU | squid-internal | `python -c "urllib.request.urlopen('http://localhost:8080/')"` |
| `valkey` | `rcao-valkey` | `valkey/valkey:8-alpine` | 128M, 0.25 CPU | squid-internal | `valkey-cli ping` |
| `squid` | `rcao-squid` | `ubuntu/squid:latest` | 256M, 0.5 CPU | squid-internal, squid-egress | TCP check on :3128 |

**Startup order:** Squid starts first; Valkey → SearXNG → Openclaw then come up in dependency order. Ollama (docker mode) runs in parallel. Openclaw waits for Squid + SearXNG to report healthy before starting.

**Resource allocation** (calculated by `setup.sh` at provisioning time):
- Ollama (docker mode only): 50% CPUs, sized from `OLLAMA_MODEL_MEM` (model memory requirement + overhead)
- Claw: 25% CPUs, fixed 512M baseline (enough for the gateway; most memory goes to Ollama)
- Squid + SearXNG + Valkey: fixed low allocations (see table)
- Reserved: remainder for host OS
- All values are written to `.env` and can be overridden before running `setup.sh`

## Volume Mounts

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `${OPENCLAW_HOME:-~/.openclaw}` | `/home/openclaw/.openclaw` | `rw` | Agent config, runtime data, memory, sessions (created by `setup.sh`, **not in repo**) |
| `${WORKSPACE:-~/workspace}` | `/workspace` | `rw` | Developer workspace — the agent reads/writes code here directly |
| `bin/` | `/openclaw/bin` | `ro` | Whitelisted gateway scripts (immutable) |
| `config/openclaw-docker-key` | `/openclaw/.ssh/id_ed25519` | `ro` | SSH private key for host access |
| `config/squid.conf` | `/etc/squid/squid.conf` | `ro` | Squid proxy ACL configuration |
| `config/searxng-settings.yml` | `/etc/searxng/settings.yml` | `ro` | SearXNG engine configuration |
| `config/searxng-limiter.toml` | `/etc/searxng/limiter.toml` | `ro` | SearXNG rate-limiter rules |
| `logs/` | `/openclaw/logs` | `rw` | Audit trail (gateway, claude, openclaw logs) |
| `logs/squid/` | `/var/log/squid` | `rw` | Squid access and cache logs |
| `ollama-models` (named volume) | `/root/.ollama` | `rw` | Persistent LLM model storage (docker mode only) |

## Directory Structure

```
rcao-claw/
├── .env.example                        # Environment config template
├── .env                                # Local config (gitignored)
├── setup.sh                            # End-to-end provisioning (pre-flight, role, SSH, Docker, verify)
├── cleanup.sh                          # Full teardown with confirmations
├── CLAUDE.md                           # Claude Code project guide
├── README.md                           # Quickstart and usage
├── CONTRIBUTING.md                     # Development and PR guidelines
├── CODE_OF_CONDUCT.md                  # Contributor Covenant v2.1
├── SECURITY.md                         # Vulnerability reporting policy
├── LICENSE                             # MIT
│
├── bin/                                # Whitelisted scripts (mounted :ro into container)
│   ├── allowed-commands.conf           # Command allowlist (literal match — 5 commands)
│   ├── ssh-gateway.sh                  # SSH ForceCommand entry point
│   ├── workspace-env.sh                # Shared workspace/env resolver (sourced)
│   ├── run-claude.sh                   # Claude Code launcher (locked down)
│   ├── git-status.sh                   # git status on workspace repo
│   ├── git-pull.sh                     # git pull --rebase on current branch
│   ├── run-tests.sh                    # npm test with optional args
│   ├── service-status.sh               # System health + available repos
│   └── test-search.sh                  # SearXNG debug helper (NOT in allowlist)
│
├── config/
│   ├── claude-settings.json            # Persistent Claude Code deny rules (co-source-of-truth)
│   ├── sshd_openclaw.conf              # SSH daemon hardening template (Match User)
│   ├── squid.conf                      # Squid proxy ACL (Slack + whitelisted search domains)
│   ├── searxng-settings.yml            # SearXNG engine configuration
│   ├── searxng-limiter.toml            # SearXNG rate-limiter rules
│   ├── slack-app-manifest.json         # Slack app template (each dev customizes)
│   ├── openclaw-docker-key(.pub)       # Ed25519 keypair (generated by setup.sh, gitignored)
│   └── authorized_keys                 # ForceCommand-restricted key (auto-generated)
│
├── personality/                        # Role-based agent personalities (version-controlled)
│   ├── shared/                         # Files common to all roles
│   │   ├── IDENTITY.md                 # Agent name & identity
│   │   └── TOOLS.md                    # Available tools reference
│   ├── developer/                      # Developer role
│   │   ├── SOUL.md                     # Persona, tone, personality traits
│   │   ├── AGENTS.md                   # Operating instructions & workflow
│   │   └── USER.md                     # User profile & preferences
│   ├── qa/                             # QA role (same structure)
│   └── marketing/                      # Marketing role (same structure)
│
├── docker/
│   ├── Dockerfile                      # node:22-slim + openssh-client (non-root UID 1001)
│   ├── docker-compose.yml              # 5 services, 5 networks
│   └── entrypoint.sh                   # SSH setup, readiness wait, gateway start
│
├── docs/
│   ├── architecture.md                 # This file
│   ├── components.md                   # Detailed component reference
│   ├── security-model.md               # Security layers & threat model
│   ├── setup-and-operations.md         # Installation & operations guide
│   ├── slack-integration.md            # Slack Socket Mode setup
│   └── testing-runbook.md              # Manual & automated test procedures
│
├── tests/                              # Test and benchmark scripts (run from host)
│   ├── benchmark-models.sh             # Model performance benchmarks
│   ├── quality-tests.sh                # Model quality test suite
│   ├── destructive-test.sh             # Full teardown + re-provision test
│   └── test-search.sh                  # SearXNG ACL + Squid egress test
│
├── .github/
│   ├── workflows/lint.yml              # CI: ShellCheck, YAML lint, JSON validation
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md               # Bug report template
│   │   └── feature_request.md          # Feature request template
│   ├── PULL_REQUEST_TEMPLATE.md        # PR template with testing checklist
│   └── CODEOWNERS                      # Security-critical path reviewers
│
├── .claude/
│   ├── rules/                          # Codebase rules enforced during Claude sessions
│   └── hooks/                          # Pre-commit hooks (secrets scan, shellcheck)
│
└── logs/                               # Audit logs (gitignored, mounted :rw)
    ├── gateway.log                     # SSH command log (all allowed/denied)
    ├── claude.log                      # Claude Code execution log
    ├── openclaw.log                    # Gateway runtime log
    └── squid/                          # Squid proxy access/cache logs
```

### Runtime state (NOT in repo)

`setup.sh` creates `~/.openclaw/` on each machine. It is managed by OpenClaw at runtime, mounted into the container as `/home/openclaw/.openclaw:rw`, and should never be committed:

```
~/.openclaw/                            # Per-machine runtime state
├── openclaw.json                       # Gateway config (mode, port, models, auth token)
├── agents/main/sessions/               # Session transcripts (JSONL)
├── credentials/                        # OAuth tokens, API keys (host-protected)
├── skills/                             # Shared managed skills
└── workspace/                          # Active personality (copied from personality/<role>/ at setup)
    ├── IDENTITY.md · TOOLS.md          # From personality/shared/
    ├── SOUL.md · AGENTS.md · USER.md   # From personality/<role>/
    ├── MEMORY.md · memory/             # Long-term memory (written at runtime)
    └── skills/                         # Workspace-specific skills
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

**Immutability guarantee:** Personality files (SOUL, AGENTS, USER, IDENTITY, TOOLS) live in the version-controlled `personality/` tree. `setup.sh` copies the selected role into `~/.openclaw/workspace/`, and the container entrypoint sets them to `chmod 444` so the agent cannot rewrite its own rules at runtime. Updates flow one way: edit `personality/<role>/*.md` in the repo, then re-run `setup.sh` to refresh the runtime copy.

## Configuration

All user configuration is managed through `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_VERSION` | `2026.4.12` | Pinned OpenClaw gateway package version |
| `WORKSPACE` | `~/workspace/my-project` | Target repo directory (Claude Code operates here) |
| `OLLAMA_MODE` | `auto` | `native` (macOS Metal GPU), `docker` (Linux/CI), or `auto` (detect by OS) |
| `OLLAMA_MODEL` | `qwen3.5:9b` | Ollama model for local inference |
| `OLLAMA_MODEL_MEM` | `10` | Model memory requirement in GiB (used to size Ollama container + preflight) |
| `SEARXNG_SECRET` | (auto-generated) | SearXNG session secret; `setup.sh` generates one if unset |
| `SLACK_APP_TOKEN` | (unset) | App-Level Token for Socket Mode (`xapp-...`) |
| `SLACK_USER_TOKEN` | (unset) | User OAuth Token (`xoxp-...`) — preferred: messages appear from the developer |
| `SLACK_BOT_TOKEN` | (unset) | Bot User OAuth Token (`xoxb-...`) — legacy bot mode |

Resource limits are auto-calculated by `setup.sh` based on system hardware and can be overridden by editing `.env`:

| Variable | setup.sh value | Description |
|----------|----------------|-------------|
| `OLLAMA_CPUS` | 50% system CPUs (docker mode) | Ollama CPU limit |
| `OLLAMA_MEM` | Sized from `OLLAMA_MODEL_MEM` + overhead (docker mode) | Ollama memory limit |
| `CLAW_CPUS` | 25% system CPUs | Claw gateway CPU limit |
| `CLAW_MEM` | 512M baseline (fixed, not a percentage) | Claw gateway memory limit |

## Host Commands (via SSH Gateway)

| Command | Script | Purpose |
|---------|--------|---------|
| `service-status` | `bin/service-status.sh` | System config, available repos, disk usage |
| `git-status [repo]` | `bin/git-status.sh` | Git working tree status |
| `git-pull [repo]` | `bin/git-pull.sh` | Git pull with rebase on current branch |
| `run-tests [repo] [-- args]` | `bin/run-tests.sh` | Run npm test suite with optional arguments |
| `run-claude <prompt> [repo]` | `bin/run-claude.sh` | Coding tasks via Claude Code (25 turns, $10 cap) |

Default workspace comes from `WORKSPACE` in `.env`. All commands accept an optional `[repo]` override (a name under the workspace parent, or a full path).

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
| 8 | Inline `deny` rules in generated `claude-run-settings.json` (passed via `--settings`) | Dangerous tools (ssh, curl, sudo, rm -rf, node -e, npx, etc.) |
| 9 | Claude `--max-turns 25` | Runaway agent loops |
| 10 | Claude `--max-budget-usd 10` | API cost overruns |
| 11 | Persistent `config/claude-settings.json` (mounted `:ro`) | Tampering with the deny rule source-of-truth |
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
- [ ] `run-claude.sh` operates on `$WORKSPACE` only
- [ ] Claude Code cannot use ssh, curl, wget, sudo, docker
- [ ] Claude Code cannot use `rm -rf`, `node -e`, `npx`
- [ ] Claude Code cannot access WebFetch/WebSearch
- [ ] All actions logged to `logs/` with ISO timestamps
- [ ] Container restart preserves agent data (volumes)
- [ ] Web UI not accessible from other machines (127.0.0.1 bind)
- [ ] Squid only allows the ACL-whitelisted domains (Slack + search/dev sources in `config/squid.conf`)
- [ ] Squid rejects any other domain with `403 Forbidden`
- [ ] Ollama has zero internet access
