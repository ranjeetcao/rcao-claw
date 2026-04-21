# Component Reference

Detailed reference for every component in the RCao Claw system. For the high-level architecture overview, see [architecture.md](architecture.md).

## Table of Contents

- [Docker Services](#docker-services)
- [SSH Gateway Scripts](#ssh-gateway-scripts)
- [Configuration Files](#configuration-files)
- [Agent Personality Files](#agent-personality-files)
- [Provisioning Scripts](#provisioning-scripts)
- [CI/CD and GitHub Config](#cicd-and-github-config)

---

## Docker Services

### openclaw (Claw Gateway)

**Container:** `rcao-claw`
**Image:** Built from `docker/Dockerfile` (base: `node:22-slim`)
**Port:** `127.0.0.1:3000:3000`

The main gateway service. Hosts the Web UI, runs local LLM inference requests to Ollama, manages agent sessions, and executes host commands via SSH.

**Dockerfile build steps:**
1. Installs `openssh-client` and `curl` via apt
2. Creates `openclaw` user (UID 1001) with `/bin/bash` shell
3. Creates directories: `/openclaw/.ssh`, `/openclaw/data`, `/openclaw/logs`, `/home/openclaw/.openclaw`
4. Installs `openclaw@${OPENCLAW_VERSION}` globally via npm
5. Exposes port 3000
6. Sets entrypoint to `/entrypoint.sh`

**Entrypoint flow (`docker/entrypoint.sh`):**
1. Copies SSH key from read-only mount to writable `~/.ssh/id_ed25519` (mode 600)
2. Adds `host.docker.internal` to SSH known_hosts via `ssh-keyscan`
3. Verifies `openclaw.json` config exists
4. Sets personality files (SOUL.md, AGENTS.md, etc.) to read-only (chmod 444)
5. Waits up to 30s for Ollama to respond at `http://ollama:11434/api/tags`
6. Starts: `openclaw gateway run --bind custom --port 3000`
7. Logs output to both stdout and `/openclaw/logs/openclaw.log`

**Environment variables:**
| Variable | Value | Purpose |
|----------|-------|---------|
| `OLLAMA_HOST` | `http://ollama:11434` | Ollama inference endpoint |
| `HTTP_PROXY` | `http://squid:3128` | HTTP proxy for outbound traffic |
| `HTTPS_PROXY` | `http://squid:3128` | HTTPS proxy (CONNECT tunneling) |
| `NO_PROXY` | `ollama,localhost,127.0.0.1,host.docker.internal` | Bypass proxy for internal traffic |
| `SLACK_BOT_TOKEN` | From `.env` | Slack bot OAuth token (optional) |
| `SLACK_APP_TOKEN` | From `.env` | Slack app-level token (optional) |

**Networks:** isolated, host-access, squid-internal, web-access
**Depends on:** ollama (healthy), squid (healthy)
**Resources:** `${CLAW_MEM:-1G}` RAM, `${CLAW_CPUS:-1}` CPUs

---

### ollama (LLM Inference)

**Container:** `rcao-ollama`
**Image:** `ollama/ollama:0.20.3` (pinned version)
**Port:** None exposed (internal only)

Runs local LLM inference using the Qwen 3.5 model. Fully air-gapped -- no internet access.

**Volume:** `ollama-models:/root/.ollama` (named Docker volume for persistent model storage)
**Network:** `isolated` only (internal, no internet)
**Health check:** `ollama list` (interval: 10s, timeout: 5s, retries: 5, start period: 30s)
**Resources:** `${OLLAMA_MEM:-4G}` RAM, `${OLLAMA_CPUS:-1.5}` CPUs

**Model download:** During setup, Ollama is temporarily connected to `squid-egress` to pull the model, then disconnected. After setup, it remains air-gapped.

---

### squid (HTTP Proxy)

**Container:** `rcao-squid`
**Image:** `ubuntu/squid:latest`
**Port:** Internal 3128 (not exposed by default; can be temporarily exposed on `127.0.0.1:3128` for debugging)

Forward proxy that controls all outbound internet access. ACL restricts traffic to Slack API domains only over HTTPS.

**Configuration (`docker/squid.conf`):**
- **Allowed domains:** `*.slack.com`, `*.slack-edge.com`
- **Allowed ports:** 443 (HTTPS only)
- **Allowed method:** CONNECT (HTTPS tunneling)
- **Denied:** All other domains, HTTP traffic, non-443 ports
- **Privacy:** `via off`, `X-Forwarded-For delete` (strips proxy headers)
- **Caching:** Disabled for API responses

**Networks:** squid-internal (openclaw <-> squid), squid-egress (squid -> internet)
**Health check:** TCP connectivity check on port 3128
**Resources:** 256M RAM, 0.5 CPUs (fixed)

---

## SSH Gateway Scripts

All scripts in `bin/` follow these conventions:
- `#!/bin/bash` + `set -euo pipefail` header
- Source `workspace-env.sh` for workspace resolution (except service-status.sh)
- Validate all inputs against shell metacharacters and path traversal
- Log to `~/openclaw/logs/` with ISO 8601 timestamps
- Use colored output helpers: `info()`, `warn()`, `error()`, `step()`

### ssh-gateway.sh

**Purpose:** SSH ForceCommand entry point. Intercepts ALL SSH sessions from the container and routes them through validation before executing allowed commands.

**Validation chain (7 stages):**

| Stage | Check | Blocks |
|-------|-------|--------|
| 1 | Command not empty | Interactive shell attempts |
| 2 | No `..` or `/` in command name | Path traversal |
| 3 | No metacharacters in command name | Command injection via name |
| 4 | No metacharacters in arguments | Command injection via args |
| 5 | Command in `allowed-commands.conf` | Unapproved commands (literal `grep -Fqx` match) |
| 6 | Script file exists and is executable | Missing/broken scripts |
| 7 | Rate limit not exceeded | Abuse (30 commands/min, sliding window with `flock`) |

**Blocked metacharacters:** `` ; | & $ ` \ ( ) { } < > ``

**Logging:** All commands (ALLOWED and DENIED) logged to `~/openclaw/logs/gateway.log` with ISO timestamps, PID, and sanitized messages (newlines and non-printable characters stripped).

**Rate limiting:** Token bucket algorithm with 60-second sliding window. Uses `flock` for atomic file access. Rate limit file at `$HOME/openclaw/.rate-limit`.

**Execution:** Uses `exec "$SCRIPT" "$CMD_ARGS"` to replace the gateway process (no subprocess overhead).

### allowed-commands.conf

**Purpose:** Allowlist of permitted command names. One command per line, literal match only (no regex, no globs).

**Current allowlist:**
```
git-status
git-pull
run-tests
run-claude
service-status
```

### workspace-env.sh

**Purpose:** Shared environment resolver sourced by all bin/ scripts. Provides consistent workspace path resolution.

**What it does:**
1. Parses `.env` safely using `grep` + `cut` (never `source .env` -- prevents code injection)
2. Resolves `REPO`, `WORKSPACE_DIR`, `OPENCLAW_VERSION` from `.env`
3. Accepts optional command-line repo override
4. Validates repo name: blocks `..`, `/`, shell metacharacters
5. Verifies target directory exists
6. Exports: `WORKDIR`, `WORKSPACE_ROOT`, `REPO`, `OPENCLAW_VERSION`

### git-status.sh

**Purpose:** Run `git status` on the workspace repository.
**Usage:** `git-status [repo-name]`
**Flow:** Source workspace-env.sh -> cd to resolved directory -> `git status`

### git-pull.sh

**Purpose:** Pull latest changes with rebase on the current branch.
**Usage:** `git-pull [repo-name]`
**Flow:** Source workspace-env.sh -> cd to resolved directory -> `git pull --rebase origin $(git branch --show-current)`

### run-tests.sh

**Purpose:** Execute the npm test suite with optional arguments.
**Usage:** `run-tests [repo-name] [-- test-args...]`

**Argument parsing:**
- Everything before `--` is treated as the repo name
- Everything after `--` is passed to `npm test`
- Each test argument is individually validated for shell metacharacters

**Flow:** Parse args -> source workspace-env.sh -> validate test args -> `npm test -- "${_TEST_ARGS[@]}"`

### run-claude.sh

**Purpose:** Launch Claude Code in locked-down mode for coding tasks.
**Usage:** `run-claude <prompt> [repo-name]`

**Security controls:**
1. **Prompt length limit:** 8000 characters max
2. **Permission mode:** `--permission-mode dontAsk` (whitelist mode)
3. **Allowed tools (27):** Read, Edit, Write, Glob, Grep, safe npm commands, safe git commands, `node src/*`/`node scripts/*`/`node dist/*`, basic utilities (ls, mkdir, rm single files, head, tail, wc, sort, which)
4. **Blocked tools (50+):** Network (curl, wget, ssh), system (sudo, docker, mount), interpreters (python, ruby, perl, awk, sed), shell escape (bash -c, sh -c, eval, exec), bulk delete (rm -rf, rm -r), destructive git (push, rebase, reset, merge, config), sandbox escape (pip, find, xargs, tee, ln), internet (WebFetch, WebSearch), arbitrary execution (node -e, npx)
5. **Execution limits:** 25 turns, $10 USD budget

**Logging:** Start and end timestamps, working directory, prompt prefix (first 100 chars), exit code -- all to `~/openclaw/logs/claude.log`.

### service-status.sh

**Purpose:** Display system configuration and health information.
**Usage:** `service-status`

**Output:** OpenClaw version, default workspace, available repos (ls of workspace root), disk usage.

---

## Configuration Files

### openclaw.json

**Location:** `openclaw-home/openclaw.json` (mounted to `/home/openclaw/.openclaw/openclaw.json`)
**Ownership:** Container (UID 1001) -- gateway writes auth token here at startup

**Key settings:**
```json
{
  "gateway": {
    "mode": "local",
    "bind": "custom",
    "customBindHost": "0.0.0.0",
    "port": 3000
  },
  "agents": {
    "defaults": {
      "workspace": "~/.openclaw/workspace",
      "sandbox": { "mode": "off" }
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://ollama:11434",
        "models": [{ "id": "gemma4:e2b", "name": "Gemma 4 E2B", "api": "ollama" }]
      }
    }
  },
  "tools": {
    "allow": ["read", "write", "edit", "message"],
    "deny": ["exec", "bash", "process", "browser", "canvas"],
    "elevated": { "enabled": false }
  },
  "channels": {
    "slack": { "enabled": true, "mode": "socket" }
  }
}
```

**Notes:**
- `bind: "custom"` with `customBindHost: "0.0.0.0"` is safe because the Docker port binding restricts to `127.0.0.1` externally
- `sandbox.mode: "off"` -- sandboxing is redundant since the entire container is the sandbox
- Auth token is written at runtime by the gateway and extracted by `setup.sh` for browser pairing

### claude-settings.json

**Location:** `config/claude-settings.json` (deployed to `$WORKSPACE_DIR/.claude/settings.json`)
**Purpose:** Persistent Claude Code deny rules that complement the CLI flags in `run-claude.sh`

**Both sources must stay in sync.** If `run-claude.sh` blocks a tool but `settings.json` doesn't (or vice versa), behavior is unpredictable.

### sshd_openclaw.conf

**Location:** `config/sshd_openclaw.conf` (installed to `/etc/ssh/sshd_config.d/openclaw.conf`)
**Purpose:** SSH daemon hardening for the `openclaw-bot` user

**Generated dynamically by `setup.sh` with:**
```
Match User openclaw-bot
    PasswordAuthentication no
    PubkeyAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    AllowAgentForwarding no
    ForceCommand /home/openclaw-bot/openclaw/bin/ssh-gateway.sh
```

### authorized_keys

**Location:** `config/authorized_keys` (installed to `~openclaw-bot/.ssh/authorized_keys`)
**Purpose:** SSH public key with ForceCommand and restriction options

**Format:**
```
command="/path/to/ssh-gateway.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... openclaw-docker
```

### squid.conf

**Location:** `docker/squid.conf` (mounted read-only into squid container)
**Purpose:** Squid proxy ACL configuration

**Key rules:**
- ACL allows only `*.slack.com` and `*.slack-edge.com`
- Only HTTPS port 443 via CONNECT method
- All other domains and ports denied
- Privacy: `via off`, `X-Forwarded-For delete`
- No caching of API responses

---

## Agent Personality Files

These files define who Claw is, how it operates, and what tools it has. They are mounted read-only and set to `chmod 444` by the entrypoint -- the agent cannot modify its own identity.

### SOUL.md

**Location:** `openclaw-home/workspace/SOUL.md`
**Purpose:** Core persona and personality traits

**Claw's identity:**
- Secure development partner running in Docker with restricted host access
- Powered by Qwen 3.5 (local) + Claude Code (for hands-on coding)
- **Deliberate** -- thinks first, acts second
- **Thorough** -- covers edge cases in plans
- **Collaborative** -- gets reviews at every stage
- **Quality-focused** -- matches project conventions exactly
- **Honest** -- reports unclear situations before proceeding
- Core principle: **Never jump to code.** Workflow is Plan -> Review -> Tasks -> Implement -> Review -> PR

### AGENTS.md

**Location:** `openclaw-home/workspace/AGENTS.md`
**Purpose:** Operating instructions and mandatory 7-step workflow

**Workflow (no shortcuts allowed):**

| Step | Action | Details |
|------|--------|---------|
| 1 | Understand | Read code, docs, check service-status and git-status |
| 2 | Plan | Write plan before touching code (what, where, why, risks) |
| 3 | Plan Review | Launch review agents (security, architecture, devex) |
| 4 | Create Tasks | Break plan into small focused tasks, one commit per task |
| 5 | Implement | Use `run-claude`, match code style, write tests alongside |
| 6 | Review | Launch agents to review completed work |
| 7 | Create PR | Feature branch, clear description, never push to main |

### USER.md

**Location:** `openclaw-home/workspace/USER.md`
**Purpose:** User profile and preferences (customizable template)

**Default preferences:** conventional commits, one concern per commit, existing test patterns, code style matching, WHY comments, concise communication, immediate error reporting.

### IDENTITY.md

**Location:** `openclaw-home/workspace/IDENTITY.md`
**Purpose:** Quick-reference agent identity

Name "Claw" -- methodical engineer who plans before building, reviews before merging, tests alongside code, follows conventions, ships through PRs.

### TOOLS.md

**Location:** `openclaw-home/workspace/TOOLS.md`
**Purpose:** Reference for all available tools, allowed/blocked lists, Slack integration details, and execution limits

Documents the full allowed/blocked tool matrix, Slack Socket Mode capabilities, proxy routing details, and security constraints.

---

## Provisioning Scripts

### setup.sh

**Purpose:** End-to-end provisioning from a clean state to a running system.

**7 phases:**

| Phase | What it does |
|-------|-------------|
| 1. Environment | Auto-create `.env` from template, parse config, preflight checks (Docker, Compose, ssh-keygen, jq), resource calculation |
| 2. Directories | Create all host directories, fix permissions for container UID 1001, protect personality files |
| 3. SSH Keys | Generate Ed25519 keypair (`config/openclaw-docker-key`), set 640 permissions with shared group |
| 4. Host User | Create `openclaw-bot` with restricted shell, install authorized_keys with ForceCommand, symlink scripts, install SSH hardening config |
| 5. Claude Config | Deploy `claude-settings.json` to `$WORKSPACE_DIR/.claude/settings.json` |
| 6. Docker | Build images, start containers, wait for health, extract auth token, auto-pair browser, optionally pull Ollama model |
| 7. Verification | Check all containers running, web UI healthy, Slack tokens present, display summary |

**Interactive prompts:** 6 confirmation prompts (user creation, SSH key install, script symlink, SSH hardening, Docker build, model pull). All default to No.

### cleanup.sh

**Purpose:** Full teardown with per-step confirmation.

**Cleanup sequence:**

| Step | What it removes | Confirmation |
|------|----------------|-------------|
| 1 | Docker containers, locally-built images, volumes | Automatic |
| 2 | SSH hardening config (`/etc/ssh/sshd_config.d/openclaw.conf`) | y/N prompt |
| 3 | SSH keypair (`config/openclaw-docker-key*`) | y/N prompt |
| 4 | `openclaw-bot` user and home directory | y/N prompt |
| 5 | Claude Code settings (`$WORKSPACE_DIR/.claude/settings.json`) | y/N prompt |
| 6 | Reclaim file ownership from container UID 1001 | Auto with sudo |
| 7 | Gateway runtime data (agents, canvas, devices, etc.) | Automatic |
| 8 | Agent data (credentials, skills, memory) | y/N + type "DELETE" |
| 9 | Log files | y/N prompt |

**Safety:** Agent data deletion requires double confirmation (y/N plus typing "DELETE").

---

## CI/CD and GitHub Config

### .github/workflows/lint.yml

**Triggers:** Push to `main`, PRs targeting `main`

| Job | Tool | Validates |
|-----|------|-----------|
| ShellCheck | `shellcheck` | `bin/*.sh`, `setup.sh`, `cleanup.sh` |
| YAML Lint | `yamllint` | `docker/docker-compose.yml` |
| JSON Validation | Python `json` | All `.json` files (excluding `.git/`) |

### Issue & PR Templates

- **Bug report** (`.github/ISSUE_TEMPLATE/bug_report.md`) -- environment info, reproduction steps
- **Feature request** (`.github/ISSUE_TEMPLATE/feature_request.md`) -- problem/solution/alternatives
- **Pull request** (`.github/PULL_REQUEST_TEMPLATE.md`) -- summary, changes, testing checklist

### .gitignore

Protects sensitive and ephemeral files:
- `.env` (secrets)
- SSH keys (`config/openclaw-docker-key*`)
- Runtime data (credentials, memory, sessions, canvas, devices, etc.)
- Logs (`logs/*.log`, `logs/squid/`)
- Rate limit files (`*.rate-limit*`)
