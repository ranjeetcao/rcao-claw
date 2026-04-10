# Setup and Operations Guide

## Prerequisites

### System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| RAM | 6 GB | 16 GB+ |
| CPU cores | 4 | 8+ |
| Disk space | 10 GB (for models + Docker images) | 20 GB+ |
| OS | macOS or Linux (Ubuntu/Debian) | -- |

### Required Tools

| Tool | Purpose | Check |
|------|---------|-------|
| Docker | Container runtime | `docker --version` |
| Docker Compose | Multi-container orchestration | `docker compose version` |
| ssh-keygen | SSH key generation | `which ssh-keygen` |
| jq | JSON parsing (token extraction) | `jq --version` |
| curl | Health checks | `which curl` |

`setup.sh` verifies all prerequisites automatically and exits with clear error messages if anything is missing.

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/zupee-labs/zupee-claw.git
cd zupee-claw
```

### 2. Configure Environment

```bash
cp .env.example .env
# Edit .env with your settings
```

**Environment variables:**

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `OPENCLAW_VERSION` | `2026.4.2` | Yes | Pinned Claw gateway version |
| `REPO` | `my-project` | Yes | Default repo directory under workspace |
| `WORKSPACE_DIR` | `~/workspace` | Yes | Base directory where dev repos live |
| `OLLAMA_MODEL` | `qwen3:1.7b` | Yes | LLM model for local inference |
| `SLACK_BOT_TOKEN` | (empty) | No | Slack bot OAuth token (`xoxb-...`) |
| `SLACK_APP_TOKEN` | (empty) | No | Slack app-level token (`xapp-...`) |

If `.env` doesn't exist when you run `setup.sh`, it will be auto-created from `.env.example`.

### 3. Run Setup

```bash
./setup.sh
```

The setup script runs through 7 phases with interactive prompts at each step. All prompts default to No -- you must explicitly type `y` to proceed.

**Phase-by-phase walkthrough:**

#### Phase 1: Environment & Preflight
- Auto-creates `.env` from `.env.example` if missing
- Parses configuration safely (grep+cut, never source)
- Checks all prerequisites (Docker, Compose, ssh-keygen, jq)
- Detects system resources (CPU, RAM)
- Calculates resource allocation for containers
- Warns if RAM < 6GB or CPUs < 4

#### Phase 2: Directory & Permissions
- Creates host directories (logs, agent data, credentials, memory)
- Fixes file ownership for container UID 1001
- Protects personality files (host-owned, read-only)
- Sets Squid log directory permissions

#### Phase 3: SSH Key Generation
- Generates Ed25519 keypair at `config/openclaw-docker-key`
- Sets permissions to 640 (host user + container group read)
- Skips if key already exists

#### Phase 4: Host User & SSH
- **Prompt:** "Create user 'openclaw-bot' with restricted shell? [y/N]"
  - macOS: creates via `dscl` with shell `/usr/bin/false`
  - Linux: creates via `useradd` with shell `rbash`
- **Prompt:** "Install SSH key for 'openclaw-bot'? [y/N]"
  - Installs authorized_keys with ForceCommand restrictions
- **Prompt:** "Symlink scripts to openclaw-bot home? [y/N]"
  - Links `bin/` and `.env` to openclaw-bot's home directory
- **Prompt:** "Install SSH hardening config? [y/N]"
  - Deploys `sshd_openclaw.conf` to `/etc/ssh/sshd_config.d/`
  - Reloads sshd (Linux) or notifies for restart (macOS)

#### Phase 5: Claude Code Config
- Deploys `config/claude-settings.json` to `$WORKSPACE_DIR/.claude/settings.json`
- Creates `.claude/` directory if it doesn't exist

#### Phase 6: Docker Build & Start
- **Prompt:** "Build and start Docker containers? [y/N]"
  - Builds openclaw image with `OPENCLAW_VERSION` build arg
  - Starts all 3 services (ollama, squid, openclaw)
  - Waits up to 90s for Web UI health check
  - Extracts gateway auth token from `openclaw.json`
  - Opens browser to `http://localhost:3000`
  - Auto-pairs browser device with gateway
- **Prompt:** "Pull Ollama model now? [y/N]"
  - Temporarily connects Ollama to internet via squid-egress
  - Pulls the configured model
  - Disconnects Ollama back to air-gapped state

#### Phase 7: Verification
- Checks all containers are running
- Verifies Web UI health endpoint
- Validates Slack tokens (if configured)
- Displays summary with auth token and access URL

### 4. Verify Installation

```bash
# Web UI accessible
curl -s http://localhost:3000/health

# Ollama responding
docker compose -f docker/docker-compose.yml exec ollama ollama list

# SSH gateway working
docker compose -f docker/docker-compose.yml exec openclaw \
  ssh -i /openclaw/.ssh/id_ed25519 openclaw-bot@host.docker.internal "service-status"

# Check logs
tail -f logs/gateway.log
```

## Daily Operations

### Starting the System

```bash
cd docker
docker compose up -d
```

Wait for health checks to pass (openclaw waits for ollama and squid to be healthy).

### Stopping the System

```bash
cd docker
docker compose down
```

This stops containers but preserves volumes (agent data, models).

### Viewing Logs

```bash
# Gateway command log (SSH commands)
tail -f logs/gateway.log

# Claude Code execution log
tail -f logs/claude.log

# Claw gateway runtime log
tail -f logs/openclaw.log

# Squid proxy access log
tail -f logs/squid/access.log

# Docker container logs
cd docker && docker compose logs -f openclaw
cd docker && docker compose logs -f ollama
cd docker && docker compose logs -f squid
```

### Checking Service Health

```bash
# All containers running?
docker ps --filter "name=zupee-"

# Web UI health
curl -sf http://localhost:3000/health

# Ollama health
docker compose -f docker/docker-compose.yml exec ollama ollama list

# SSH gateway test
docker compose -f docker/docker-compose.yml exec openclaw \
  ssh -i /openclaw/.ssh/id_ed25519 openclaw-bot@host.docker.internal "service-status"
```

### Working with Repos

The default repo is set in `.env` as `REPO`. All gateway commands accept an optional repo override:

```bash
# Default repo
ssh openclaw-bot@host "git-status"

# Specific repo
ssh openclaw-bot@host "git-status other-project"
```

Available repos are any directories under `$WORKSPACE_DIR/`.

## Adding a New Command

1. Create the script:
   ```bash
   cat > bin/my-command.sh << 'EOF'
   #!/bin/bash
   set -euo pipefail
   source "$(dirname "${BASH_SOURCE[0]}")/workspace-env.sh" "${1:-}"
   # Your command logic here
   EOF
   chmod +x bin/my-command.sh
   ```

2. Add to allowlist:
   ```bash
   echo "my-command" >> bin/allowed-commands.conf
   ```

3. Test via SSH:
   ```bash
   docker compose -f docker/docker-compose.yml exec openclaw \
     ssh -i /openclaw/.ssh/id_ed25519 openclaw-bot@host.docker.internal "my-command"
   ```

4. Run ShellCheck:
   ```bash
   shellcheck bin/my-command.sh
   ```

## Updating Claw Version

1. Edit `.env`:
   ```bash
   OPENCLAW_VERSION=2026.5.0
   ```

2. Rebuild and restart:
   ```bash
   cd docker
   docker compose build --build-arg OPENCLAW_VERSION=2026.5.0
   docker compose up -d
   ```

## Changing the LLM Model

1. Edit `.env`:
   ```bash
   OLLAMA_MODEL=llama3.1
   ```

2. Pull the new model (requires temporary internet access):
   ```bash
   # Connect Ollama to internet temporarily
   docker network connect zupee-claw_squid-egress zupee-ollama

   # Pull model
   docker compose -f docker/docker-compose.yml exec ollama ollama pull llama3.1

   # Disconnect from internet
   docker network disconnect zupee-claw_squid-egress zupee-ollama
   ```

3. Update `openclaw.json` to reference the new model ID.

## Model Benchmarks

Benchmarks run on **Apple M4 Pro** (14 CPUs, 20 GPU cores, 24 GB RAM) using native Ollama with Metal GPU acceleration. Each prompt was run 3 times and averaged across 4 prompt types (short, medium, coding, reasoning).

### Results (2026-04-10)

| Model | Params | Disk | Avg tok/s | Avg Latency | Cold Start | Quality | Rating |
|-------|--------|------|-----------|-------------|------------|---------|--------|
| **qwen3:8b** | 8B | 5.2 GB | **45.5** | **3.96s** | 3.59s (2.40s load) | 3/3 | ★★★ Excellent |
| qwen3.5:4b | 4B | 3.4 GB | 38.5 | 6.59s | 11.34s (10.07s load) | 3/3 | ★★★ Excellent |
| qwen3.5:9b | 9B | 6.6 GB | 28.6 | 9.84s | 6.50s (4.53s load) | 3/3 | ★★☆ Good |

### Key Findings

- **qwen3:8b** is the fastest model overall at 45.5 tok/s with the lowest latency (3.96s avg) and fastest cold start (3.59s). Best all-round pick for this hardware.
- **qwen3.5:4b** offers a good balance — smaller disk footprint (3.4 GB) with solid throughput (38.5 tok/s), though cold start is slower (11.34s).
- **qwen3.5:9b** has the highest quality responses (longer, more detailed) but is the slowest at 28.6 tok/s. Better suited for machines with more memory/GPU headroom.
- All three models passed all quality checks (greeting, coding with `def`, reasoning with correct answer of 9).

### Running Benchmarks

```bash
# Benchmark all candidate models
./bin/benchmark-models.sh

# Benchmark a specific model
./bin/benchmark-models.sh qwen3:8b

# Benchmark only installed models
./bin/benchmark-models.sh --installed
```

## Slack Integration

See [slack-integration.md](slack-integration.md) for full Slack setup instructions.

**Quick summary:**
1. Create a Slack App with Socket Mode enabled
2. Set `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` in `.env`
3. Restart containers

Both tokens are required for Socket Mode. The Squid proxy ACL allows only `*.slack.com` and `*.slack-edge.com` on port 443.

## Teardown

```bash
./cleanup.sh
```

The cleanup script walks through each component with individual confirmation prompts:

| Step | What it removes | Requires Confirmation |
|------|----------------|----------------------|
| Docker containers, images, volumes | Automatic |
| SSH hardening config | y/N |
| SSH keypair | y/N |
| `openclaw-bot` user + home | y/N |
| Claude Code settings | y/N |
| Gateway runtime data | Automatic |
| Agent data (credentials, memory, skills) | y/N + type "DELETE" |
| Log files | y/N |

**Agent data deletion** is protected by double confirmation (prompt + typing "DELETE") because it is irreversible.

## Troubleshooting

### Web UI not accessible

```bash
# Check container is running
docker ps --filter "name=zupee-claw"

# Check health endpoint
curl -v http://localhost:3000/health

# Check container logs
cd docker && docker compose logs openclaw

# Verify port binding
docker port zupee-claw
# Should show: 3000/tcp -> 127.0.0.1:3000
```

### SSH gateway connection refused

```bash
# Check openclaw-bot user exists
id openclaw-bot

# Check SSH config installed
cat /etc/ssh/sshd_config.d/openclaw.conf

# Check authorized_keys
cat ~openclaw-bot/.ssh/authorized_keys

# Check SSH key in container
docker exec zupee-claw ls -la /home/openclaw/.ssh/

# Test SSH manually
docker exec zupee-claw ssh -v -i /home/openclaw/.ssh/id_ed25519 \
  openclaw-bot@host.docker.internal "service-status"
```

### Ollama not responding

```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' zupee-ollama

# Check Ollama logs
cd docker && docker compose logs ollama

# Check model is pulled
docker compose -f docker/docker-compose.yml exec ollama ollama list

# Verify network connectivity from openclaw
docker exec zupee-claw curl -s http://ollama:11434/api/tags
```

### Claude Code commands failing

```bash
# Check claude.log for errors
tail -20 logs/claude.log

# Verify Claude settings deployed
cat $WORKSPACE_DIR/.claude/settings.json

# Check workspace directory exists
ls -la $WORKSPACE_DIR/$REPO/
```

### Permission errors (file ownership)

Container runs as UID 1001. If files are owned by a different UID:

```bash
# Reclaim ownership of runtime directories
sudo chown -R 1001:1001 openclaw-home/agents/ openclaw-home/workspace/memory/

# Reclaim for host access
sudo chown -R $(id -u):$(id -g) openclaw-home/ logs/
```

### Rate limiting triggered

The SSH gateway allows 30 commands per 60-second window. If rate limited:

```bash
# Check rate limit file
cat ~openclaw-bot/openclaw/.rate-limit

# Wait 60 seconds for window to expire
# Rate limit file entries older than 60s are automatically cleaned
```

### Squid proxy issues

```bash
# Check Squid container
docker ps --filter "name=zupee-squid"

# Check Squid logs
tail -f logs/squid/access.log

# Test Slack connectivity through proxy
curl --proxy http://127.0.0.1:3128 https://slack.com/api/api.test

# Test that non-Slack domains are blocked
curl --proxy http://127.0.0.1:3128 https://google.com
# Should return 403

# Restart Squid
cd docker && docker compose restart squid
```

### Container resource issues

If containers are OOM-killed or CPU-throttled:

```bash
# Check resource usage
docker stats zupee-claw zupee-ollama zupee-squid

# Check for OOM kills
docker inspect --format='{{.State.OOMKilled}}' zupee-ollama

# Increase limits in .env or docker-compose.yml
# Ollama needs the most resources (50% RAM recommended)
```

## Resource Allocation Reference

`setup.sh` auto-calculates resource limits based on system hardware:

| Service | CPU Allocation | RAM Allocation | Minimum |
|---------|---------------|----------------|---------|
| Ollama | 50% of system CPUs | 50% of system RAM | 0.5 CPU |
| Claw | 25% of system CPUs | 20% of system RAM | 0.25 CPU |
| Squid | Fixed 0.5 CPU | Fixed 256M | -- |
| Reserved | ~25% CPUs, ~30% RAM | For host OS | -- |

Override by setting `OLLAMA_MEM`, `OLLAMA_CPUS`, `CLAW_MEM`, `CLAW_CPUS` in your environment before running Docker Compose.
