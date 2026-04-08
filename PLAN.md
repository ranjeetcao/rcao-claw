# Zupee Claw - Secure Office Laptop Setup Plan

## Overview

Run Claw inside Docker on an office laptop with local Qwen 3.5 inference.
The AI can only execute pre-approved scripts on the host via SSH, and can launch
Claude Code in a locked-down mode for coding tasks on the dev workspace.

**Key separation:**
- `zupee-claw/` = Claw's home (configs, agent data, sessions, memory, scripts, docker)
- `~/workspace/` = actual development codebase (where Claude Code operates)

## Architecture

```
+---------------------------------------------------------------+
|  DOCKER CONTAINER                                             |
|                                                               |
|  +-------------+     +-------------+     +-----------------+  |
|  |  Claw       |---->|   Qwen 3.5  |     | /openclaw/bin/  |  |
|  |  Gateway    |     |   (Ollama)  |     | (ro mount from  |  |
|  |  + Web UI   |     +-------------+     |  host)          |  |
|  +------+------+                         +-----------------+  |
|         |                                                     |
|  Mounted volumes:                                             |
|    ~/.openclaw/       -> zupee-claw/openclaw-home/  (rw)  |
|    /openclaw/bin/     -> zupee-claw/bin/            (ro)  |
|    /openclaw/logs/    -> zupee-claw/logs/           (rw)  |
|                                                               |
+---------|-----------------------------------------------------+
          | SSH (host.docker.internal:22)
          | ForceCommand = ssh-gateway.sh
          | Only whitelisted scripts
          |
+---------|-----------------------------------------------------+
|  HOST MACHINE                                                 |
|                                                               |
|  zupee-claw/                                              |
|    bin/           -> whitelisted scripts                      |
|    config/        -> ssh keys, host ssh config                |
|    openclaw-home/ -> ~/.openclaw in container (agents,        |
|                      workspace, sessions, memory, skills)     |
|    logs/          -> audit logs                               |
|                                                               |
|  ~/workspace/                                        |
|    (actual dev codebase - Claude Code works here)             |
|    .claude/settings.json  -> locked-down permissions          |
|                                                               |
|  User: openclaw-bot (restricted, no sudo, rbash)              |
+---------------------------------------------------------------+
```

## Directory Structure

```
zupee-claw/                         # Claw's entire home
├── PLAN.md                             # This file
├── bin/                                # Whitelisted scripts (mounted :ro)
│   ├── allowed-commands.conf           # Allowlist of permitted commands
│   ├── ssh-gateway.sh                      # SSH ForceCommand - validates & routes
│   ├── run-claude.sh                   # Launch claude -p (locked down)
│   ├── git-status.sh                   # Git status of f2p-root
│   ├── git-pull.sh                     # Git pull on f2p-root
│   ├── run-tests.sh                    # Run tests in f2p-root
│   ├── deploy-staging.sh              # Deploy to staging
│   └── service-status.sh              # Check service health
├── config/
│   ├── openclaw.config.json            # Claw gateway configuration
│   ├── openclaw-docker-key             # SSH private key (generated)
│   ├── openclaw-docker-key.pub         # SSH public key (generated)
│   ├── authorized_keys                 # ForceCommand-restricted key
│   ├── claude-settings.json            # Claude Code lockdown (copy to f2p-root)
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
│   │   ├── HEARTBEAT.md               # Heartbeat run checklist (optional)
│   │   ├── BOOT.md                     # Gateway restart checklist (optional)
│   │   ├── memory/                     # Daily memory logs
│   │   │   └── YYYY-MM-DD.md          # One file per day
│   │   ├── skills/                     # Workspace-specific skills
│   │   │   └── <skill-name>/
│   │   │       └── SKILL.md
│   │   └── canvas/                     # Canvas UI files (optional)
│   │       └── index.html
│   ├── agents/                         # Per-agent runtime state
│   │   └── main/
│   │       ├── agent/
│   │       │   └── auth-profiles.json
│   │       └── sessions/              # Session transcripts (JSONL)
│   │           └── *.jsonl
│   ├── credentials/                    # OAuth tokens, API keys
│   └── skills/                         # Shared managed skills
├── docker/
│   ├── Dockerfile                      # Claw + SSH client
│   ├── docker-compose.yml              # Full stack (openclaw + ollama)
│   └── entrypoint.sh                   # Container startup
└── logs/                               # Audit logs (mounted :rw)
    ├── gateway.log                     # SSH command log
    ├── claude.log                      # Claude Code execution log
    └── openclaw.log                    # Claw gateway log

~/workspace/                   # Dev codebase (SEPARATE)
├── .claude/
│   └── settings.json                   # Claude Code lockdown permissions
├── src/                                # Your actual source code
├── package.json
└── ...
```

### Agent workspace files explained

| File | Purpose | When loaded |
|------|---------|-------------|
| `AGENTS.md` | Operating instructions, rules, priorities | Every session start |
| `SOUL.md` | Persona, tone, personality boundaries | Every session start |
| `USER.md` | Who you are, how agent should address you | Every session start |
| `IDENTITY.md` | Agent name, emoji, vibe | Every session start |
| `TOOLS.md` | Notes about local tools & conventions | Every session start |
| `MEMORY.md` | Curated long-term memory | Main session only |
| `memory/YYYY-MM-DD.md` | Daily memory log | Reads today + yesterday |
| `HEARTBEAT.md` | Tiny checklist for heartbeat cron runs | Heartbeat mode only |
| `BOOT.md` | Startup checklist on gateway restart | Gateway restart only |
| `skills/<name>/SKILL.md` | Custom skills for this agent | On skill invocation |

## Phase 1: Host Preparation

### 1.1 Create restricted user

```bash
# Create user with restricted shell
sudo useradd -m -s /bin/rbash openclaw-bot
sudo mkdir -p /home/openclaw-bot/.ssh
sudo chmod 700 /home/openclaw-bot/.ssh

# No sudo access - do NOT add to sudoers

# Give openclaw-bot read access to f2p-root (for Claude Code)
sudo usermod -aG $(stat -f '%Sg' ~/workspace) openclaw-bot
```

### 1.2 Create directory structure

```bash
cd zupee-claw/
mkdir -p bin config data/{agents,sessions,memory,credentials} docker logs
```

### 1.3 Generate SSH keypair for Docker -> Host

```bash
ssh-keygen -t ed25519 -f zupee-claw/config/openclaw-docker-key -N "" -C "openclaw-docker"
```

### 1.4 Configure authorized_keys with ForceCommand

Place in `zupee-claw/config/authorized_keys`:

```
command="/home/openclaw-bot/openclaw/bin/ssh-gateway.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... openclaw-docker
```

Then symlink to the restricted user's home:

```bash
sudo cp zupee-claw/config/authorized_keys /home/openclaw-bot/.ssh/authorized_keys
sudo chown openclaw-bot:openclaw-bot /home/openclaw-bot/.ssh/authorized_keys
sudo chmod 600 /home/openclaw-bot/.ssh/authorized_keys
```

### 1.5 Host SSH hardening

Place in `zupee-claw/config/sshd_openclaw.conf`, then copy to `/etc/ssh/sshd_config.d/`:

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

### 1.6 Setup Claude Code permissions in f2p-root

```bash
mkdir -p ~/workspace/.claude
# settings.json created in Phase 4
```

## Phase 2: Whitelisted Scripts

### 2.1 allowed-commands.conf

```
git-status
git-pull
run-tests
run-claude
deploy-staging
service-status
```

### 2.2 ssh-gateway.sh (SSH ForceCommand)

The single entry point. Every SSH command goes through here.

Security properties:
- Reads allowlist from `allowed-commands.conf`
- Strips path traversal attempts (`../`, absolute paths)
- Logs every attempt (allowed AND denied) with timestamp, source IP
- Arguments passed through but each script validates its own
- Exit code forwarded back to caller
- Rejects empty commands and unknown commands

### 2.3 run-claude.sh

Launches Claude Code locked to `~/workspace/`:

```bash
#!/bin/bash
set -euo pipefail

WORKDIR="$HOME/workspace/f2p-root"
LOGFILE="$HOME/openclaw/logs/claude.log"
PROMPT="${1:?Usage: run-claude <prompt>}"

# Sanitize: reject prompts containing shell metacharacters
if [[ "$PROMPT" =~ [\;\|\&\$\`\\] ]]; then
    echo "DENIED: prompt contains shell metacharacters" | tee -a "$LOGFILE"
    exit 1
fi

echo "[$(date -Iseconds)] CLAUDE START: ${PROMPT:0:100}..." >> "$LOGFILE"

cd "$WORKDIR"

claude -p "$PROMPT" \
  --permission-mode dontAsk \
  --allowedTools '"Read" "Edit" "Write" "Glob" "Grep" "Bash(npm test *)" "Bash(npm run *)" "Bash(git diff *)" "Bash(git log *)" "Bash(git status)" "Bash(git add *)" "Bash(git commit *)"' \
  --disallowedTools '"Bash(curl *)" "Bash(wget *)" "Bash(rm -rf *)" "Bash(ssh *)" "Bash(sudo *)" "Bash(chmod *)" "Bash(chown *)" "Bash(kill *)" "Bash(pkill *)" "Bash(dd *)" "Bash(mkfs *)" "Bash(mount *)" "Bash(docker *)" "Bash(nc *)" "Bash(python -c *)" "Bash(python3 -c *)" "Bash(eval *)" "Bash(exec *)" "Bash(nohup *)" "Bash(crontab *)" "WebFetch" "WebSearch"' \
  --max-turns 15 \
  --max-budget-usd 10.00 \
  2>&1 | tee -a "$LOGFILE"

EXIT_CODE=${PIPESTATUS[0]}
echo "[$(date -Iseconds)] CLAUDE END: exit=$EXIT_CODE" >> "$LOGFILE"
exit $EXIT_CODE
```

### 2.4 Other utility scripts

All scripts:
- Hardcode `WORKDIR="$HOME/workspace/f2p-root"` (no user-controlled paths)
- Validate arguments (reject shell metacharacters)
- Log to `~/openclaw/logs/`
- Use `set -euo pipefail`

Example `git-status.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$HOME/workspace/f2p-root"
git status
```

Example `run-tests.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$HOME/workspace/f2p-root"
npm test -- "${@}"
```

## Phase 3: Docker Setup

### 3.1 docker-compose.yml

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    container_name: zupee-ollama
    volumes:
      - ollama-models:/root/.ollama
    deploy:
      resources:
        limits:
          memory: 8G
          cpus: "4"
    networks:
      - internal
    restart: unless-stopped

  openclaw:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: zupee-claw
    ports:
      - "127.0.0.1:3000:3000"       # Web UI (localhost only)
    volumes:
      # Claw agent workspace (sessions, memory, agents)
      - ../data:/openclaw/data:rw
      # Claw config (gateway config, model settings)
      - ../config/openclaw.config.json:/openclaw/config.json:ro
      # Whitelisted scripts (read-only for inspection)
      - ../bin:/openclaw/bin:ro
      # SSH key for host access
      - ../config/openclaw-docker-key:/openclaw/.ssh/id_ed25519:ro
      # Audit logs
      - ../logs:/openclaw/logs:rw
    environment:
      - OPENCLAW_CONFIG=/openclaw/config.json
      - OPENCLAW_DATA_DIR=/openclaw/data
      - OLLAMA_HOST=http://ollama:11434
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - ollama
    networks:
      - internal
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: "2"
    restart: unless-stopped

volumes:
  ollama-models:

networks:
  internal:
    driver: bridge
```

### 3.2 Dockerfile

```dockerfile
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g openclaw@latest

RUN useradd -m -s /bin/bash openclaw && \
    mkdir -p /openclaw/.ssh /openclaw/data /openclaw/logs && \
    chown -R openclaw:openclaw /openclaw

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER openclaw
WORKDIR /openclaw

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
```

### 3.3 entrypoint.sh

```bash
#!/bin/bash
set -euo pipefail

# Fix SSH key permissions (mounted as root-owned)
cp /openclaw/.ssh/id_ed25519 /tmp/openclaw-key
chmod 600 /tmp/openclaw-key

# Add host to known_hosts (first-run)
ssh-keyscan -H host.docker.internal >> ~/.ssh/known_hosts 2>/dev/null || true

# Start Claw gateway
exec openclaw gateway run \
  --bind 0.0.0.0 \
  --port 3000 \
  --force \
  2>&1 | tee /openclaw/logs/openclaw.log
```

### 3.4 Claw Configuration (`config/openclaw.config.json`)

```json
{
  "gateway": {
    "mode": "local",
    "bind": "0.0.0.0",
    "port": 3000
  },
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "off"
      }
    }
  },
  "models": {
    "default": "qwen3.5",
    "providers": {
      "ollama": {
        "baseUrl": "http://ollama:11434"
      }
    }
  },
  "tools": {
    "allow": ["exec", "read", "write", "edit"],
    "deny": ["browser", "canvas"],
    "elevated": {
      "enabled": false
    }
  }
}
```

Sandbox is `off` because the Docker container IS the sandbox.

## Phase 4: Claude Code Lockdown for f2p-root

### 4.1 ~/workspace/.claude/settings.json

```json
{
  "permissions": {
    "defaultMode": "dontAsk",
    "allow": [
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep",
      "Bash(npm test *)",
      "Bash(npm run lint *)",
      "Bash(npm run build *)",
      "Bash(npm run dev *)",
      "Bash(git diff *)",
      "Bash(git log *)",
      "Bash(git status)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git branch *)",
      "Bash(git checkout *)",
      "Bash(node *)",
      "Bash(npx *)",
      "Bash(ls *)",
      "Bash(cat package.json)",
      "Bash(cat tsconfig.json)"
    ],
    "deny": [
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(ssh *)",
      "Bash(sudo *)",
      "Bash(su *)",
      "Bash(rm -rf *)",
      "Bash(chmod *)",
      "Bash(chown *)",
      "Bash(kill *)",
      "Bash(pkill *)",
      "Bash(dd *)",
      "Bash(nc *)",
      "Bash(ncat *)",
      "Bash(python -c *)",
      "Bash(python3 -c *)",
      "Bash(eval *)",
      "Bash(exec *)",
      "Bash(nohup *)",
      "Bash(crontab *)",
      "Bash(docker *)",
      "Bash(mount *)",
      "Bash(umount *)",
      "Bash(open *)",
      "Bash(xdg-open *)",
      "Bash(pbcopy *)",
      "Bash(osascript *)",
      "WebFetch",
      "WebSearch"
    ]
  }
}
```

## Phase 5: Startup & Verification

### 5.1 First-time setup

```bash
# 1. Create host user & SSH config
sudo cp zupee-claw/config/sshd_openclaw.conf /etc/ssh/sshd_config.d/
sudo systemctl reload sshd

# 2. Generate SSH key
ssh-keygen -t ed25519 -f zupee-claw/config/openclaw-docker-key -N "" -C "openclaw-docker"

# 3. Install authorized_keys
sudo cp zupee-claw/config/authorized_keys /home/openclaw-bot/.ssh/authorized_keys
sudo chown openclaw-bot:openclaw-bot /home/openclaw-bot/.ssh/authorized_keys

# 4. Setup Claude Code permissions in dev workspace
mkdir -p ~/workspace/.claude
cp zupee-claw/claude-settings.json ~/workspace/.claude/settings.json

# 5. Build & start
cd zupee-claw/docker
docker compose up -d --build

# 6. Pull Qwen 3.5 model
docker compose exec ollama ollama pull qwen3.5
```

### 5.2 Daily startup

```bash
cd zupee-claw/docker
docker compose up -d
# Web UI at http://localhost:3000
```

### 5.3 Verification checklist

```bash
# Claw running?
curl -s http://localhost:3000/health

# Ollama responding?
docker compose exec ollama ollama list

# SSH gateway works?
docker compose exec openclaw ssh -i /tmp/openclaw-key \
  openclaw-bot@host.docker.internal "service-status"

# Blocked command rejected?
docker compose exec openclaw ssh -i /tmp/openclaw-key \
  openclaw-bot@host.docker.internal "rm -rf /"
# Should see: DENIED in gateway.log

# Claude Code locked down?
cd ~/workspace
claude -p "run curl google.com" --permission-mode dontAsk
# Should fail / be denied

# Logs flowing?
tail -f zupee-claw/logs/gateway.log
tail -f zupee-claw/logs/claude.log
```

- [ ] Claw web UI accessible at localhost:3000
- [ ] Qwen 3.5 responding via Ollama
- [ ] SSH from container to host works for allowed commands
- [ ] SSH gateway blocks non-whitelisted commands
- [ ] SSH gateway blocks path traversal attempts
- [ ] run-claude.sh operates on ~/workspace only
- [ ] Claude Code cannot SSH, curl, wget, rm -rf
- [ ] Claude Code cannot access WebFetch/WebSearch
- [ ] All actions logged to zupee-claw/logs/
- [ ] Container restart preserves agent data (data/ volume)
- [ ] Web UI not accessible from other machines (127.0.0.1 bind)

## Data Flow Summary

```
You (browser)
  |
  v
localhost:3000 (Claw Web UI)
  |
  v
Claw Gateway (Docker) -- inference --> Ollama/Qwen 3.5 (Docker)
  |
  | (needs host action)
  v
SSH -> ssh-gateway.sh -> allowed-commands.conf
  |
  +-- service-status.sh    (check health)
  +-- git-status.sh        (git status on f2p-root)
  +-- git-pull.sh          (git pull on f2p-root)
  +-- run-tests.sh         (npm test on f2p-root)
  +-- deploy-staging.sh    (deploy)
  +-- run-claude.sh        (locked-down Claude Code on f2p-root)
        |
        v
      claude -p "..." --dontAsk --allowedTools --max-turns 15
        |
        v
      ~/workspace/  (Read, Edit, Write, git, npm test)
```

## Security Summary

| Layer | What it does | Blocks |
|-------|-------------|--------|
| Docker | Process/filesystem isolation | Direct host access |
| 127.0.0.1 bind | Web UI on localhost only | Network exposure |
| SSH ForceCommand | Single entry point to host | Arbitrary command execution |
| ssh-gateway.sh | Command allowlist + logging | Unapproved scripts |
| Script arg validation | Input sanitization | Injection attacks |
| Claude --dontAsk | Tool whitelist mode | Unapproved tools |
| Claude --disallowedTools | Tool blacklist | ssh, curl, rm, sudo, docker |
| Claude --max-turns 15 | Execution limit | Runaway loops |
| Claude --max-budget-usd | Cost cap | API cost overruns |
| .claude/settings.json | Persistent deny rules | Bypass via flags |
| rbash user | Restricted shell | Shell escapes |
| Read-only mount | Script integrity | Script tampering from container |
| Audit logs | Full command history | Undetected misuse |
| Docker resource limits | Memory/CPU caps | Resource exhaustion |

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Script argument injection | Medium | Input validation, metachar rejection |
| Docker container escape | Very Low | No --privileged, keep Docker updated |
| SSH key theft from container | Low | Key is read-only, rotate periodically |
| Claude bypassing tool restrictions | Very Low | Triple layer: flags + settings.json + dontAsk |
| Ollama model data exfiltration | Low | No outbound network for Ollama container |
| IT detecting Docker usage | Medium | Check IT policy BEFORE setup |
| Resource exhaustion (Qwen 3.5) | Medium | Docker memory/CPU limits in compose |
| Claude reading files outside f2p-root | Low | Use --add-dir or enable sandbox mode |
