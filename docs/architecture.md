# Architecture

## Overview

Zupee Claw runs inside Docker on a local machine with local LLM inference via Ollama.
The AI can only execute pre-approved scripts on the host via SSH, and can launch
Claude Code in a locked-down mode for coding tasks on the dev workspace.

**Key separation:**
- `zupee-claw/` = Claw's home (configs, agent data, sessions, memory, scripts, docker)
- `$WORKSPACE_DIR/` = actual development codebase (where Claude Code operates)

## Architecture Diagram

```
+---------------------------------------------------------------+
|  DOCKER CONTAINER                                             |
|                                                               |
|  +-------------+     +-------------+     +-----------------+  |
|  |  Claw       |---->|   LLM       |     | /openclaw/bin/  |  |
|  |  Gateway    |     |   (Ollama)  |     | (ro mount from  |  |
|  |  + Web UI   |     +-------------+     |  host)          |  |
|  +------+------+                         +-----------------+  |
|         |                                                     |
|  Mounted volumes:                                             |
|    ~/.openclaw/       -> zupee-claw/openclaw-home/  (rw)      |
|    /openclaw/bin/     -> zupee-claw/bin/            (ro)      |
|    /openclaw/logs/    -> zupee-claw/logs/           (rw)      |
|                                                               |
+---------|-----------------------------------------------------+
          | SSH (host.docker.internal:22)
          | ForceCommand = ssh-gateway.sh
          | Only whitelisted scripts
          |
+---------|-----------------------------------------------------+
|  HOST MACHINE                                                 |
|                                                               |
|  zupee-claw/                                                  |
|    bin/           -> whitelisted scripts                      |
|    config/        -> ssh keys, host ssh config                |
|    openclaw-home/ -> ~/.openclaw in container (agents,        |
|                      workspace, sessions, memory, skills)     |
|    logs/          -> audit logs                               |
|                                                               |
|  $WORKSPACE_DIR/                                              |
|    (actual dev codebase - Claude Code works here)             |
|    .claude/settings.json  -> locked-down permissions          |
|                                                               |
|  User: openclaw-bot (restricted, no sudo, rbash)              |
+---------------------------------------------------------------+
```

## Directory Structure

```
zupee-claw/                             # Claw's entire home
├── .env.example                        # Environment configuration template
├── setup.sh                            # End-to-end provisioning
├── cleanup.sh                          # Full teardown
├── bin/                                # Whitelisted scripts (mounted :ro)
│   ├── allowed-commands.conf           # Allowlist of permitted commands
│   ├── ssh-gateway.sh                  # SSH ForceCommand - validates & routes
│   ├── workspace-env.sh               # Shared workspace resolver
│   ├── run-claude.sh                   # Launch Claude Code (locked down)
│   ├── git-status.sh                   # Git status on repo
│   ├── git-pull.sh                     # Git pull on repo
│   ├── run-tests.sh                    # Run tests in repo
│   └── service-status.sh              # Check service health
├── config/
│   ├── openclaw.config.json            # Claw gateway configuration
│   ├── openclaw-docker-key             # SSH private key (generated)
│   ├── openclaw-docker-key.pub         # SSH public key (generated)
│   ├── authorized_keys                 # ForceCommand-restricted key
│   ├── claude-settings.json            # Claude Code lockdown settings
│   └── sshd_openclaw.conf             # Host SSH hardening config
├── openclaw-home/                      # Maps to ~/.openclaw inside container
│   ├── openclaw.json                   # Main Claw config
│   ├── workspace/                      # Agent workspace (personality & memory)
│   │   ├── AGENTS.md                   # Operating instructions & rules
│   │   ├── SOUL.md                     # Persona, tone, boundaries
│   │   ├── USER.md                     # User profile & preferences
│   │   ├── IDENTITY.md                 # Agent name, vibe, emoji
│   │   ├── TOOLS.md                    # Notes about available tools
│   │   ├── MEMORY.md                   # Curated long-term memory
│   │   ├── memory/                     # Daily memory logs
│   │   └── skills/                     # Workspace-specific skills
│   ├── agents/                         # Per-agent runtime state
│   │   └── main/sessions/              # Session transcripts (JSONL)
│   ├── credentials/                    # OAuth tokens, API keys
│   └── skills/                         # Shared managed skills
├── docker/
│   ├── Dockerfile                      # Claw + SSH client
│   ├── docker-compose.yml              # Full stack (openclaw + ollama)
│   └── entrypoint.sh                   # Container startup
├── docs/
│   └── architecture.md                 # This file
└── logs/                               # Audit logs (mounted :rw)
    ├── gateway.log                     # SSH command log
    ├── claude.log                      # Claude Code execution log
    └── openclaw.log                    # Claw gateway log
```

### Agent Workspace Files

| File | Purpose | When loaded |
|------|---------|-------------|
| `AGENTS.md` | Operating instructions, rules, priorities | Every session start |
| `SOUL.md` | Persona, tone, personality boundaries | Every session start |
| `USER.md` | Who you are, how agent should address you | Every session start |
| `IDENTITY.md` | Agent name, emoji, vibe | Every session start |
| `TOOLS.md` | Notes about local tools & conventions | Every session start |
| `MEMORY.md` | Curated long-term memory | Main session only |
| `memory/YYYY-MM-DD.md` | Daily memory log | Reads today + yesterday |
| `skills/<name>/SKILL.md` | Custom skills for this agent | On skill invocation |

> **Note:** `MEMORY.md` and `memory/` files are created at runtime by the agent during its first session. They do not ship with the repository.

## Data Flow

```
You (browser)
  |
  v
localhost:3000 (Claw Web UI)
  |
  v
Claw Gateway (Docker) -- inference --> Ollama LLM (Docker)
  |
  | (needs host action)
  v
SSH -> ssh-gateway.sh -> allowed-commands.conf
  |
  +-- service-status.sh    (check health)
  +-- git-status.sh        (git status on repo)
  +-- git-pull.sh          (git pull on repo)
  +-- run-tests.sh         (npm test on repo)
  +-- run-claude.sh        (locked-down Claude Code on repo)
        |
        v
      claude -p "..." --dontAsk --allowedTools --max-turns 25
        |
        v
      $WORKSPACE_DIR/$REPO  (Read, Edit, Write, git, npm test)
```

## Security Layers

| Layer | What it does | Blocks |
|-------|-------------|--------|
| Docker | Process/filesystem isolation | Direct host access |
| 127.0.0.1 bind | Web UI on localhost only | Network exposure |
| SSH ForceCommand | Single entry point to host | Arbitrary command execution |
| ssh-gateway.sh | Command allowlist + logging | Unapproved scripts |
| Script arg validation | Input sanitization | Injection attacks |
| Claude --dontAsk | Tool whitelist mode | Unapproved tools |
| Claude --disallowedTools | Tool blacklist | ssh, curl, rm, sudo, docker |
| Claude --max-turns | Execution limit | Runaway loops |
| Claude --max-budget-usd | Cost cap | API cost overruns |
| .claude/settings.json | Persistent deny rules | Bypass via flags |
| rbash user | Restricted shell | Shell escapes |
| Read-only mount | Script integrity | Script tampering from container |
| Audit logs | Full command history | Undetected misuse |
| Docker resource limits | Memory/CPU caps | Resource exhaustion |

## Configuration

All configuration is managed through `.env`. See `.env.example` for available options:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_VERSION` | `2026.4.2` | Pinned Claw version |
| `REPO` | `my-project` | Default repository name under `$WORKSPACE_DIR/` |
| `WORKSPACE_DIR` | `~/workspace` | Root directory where repos live |
| `OLLAMA_MODEL` | `qwen3.5` | Ollama model for local inference |
