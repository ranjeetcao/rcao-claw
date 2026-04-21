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
git clone https://github.com/ranjeetcao/rcao-claw.git
cd rcao-claw
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
| `OLLAMA_MODEL` | `gemma4:e2b` | Yes | LLM model for local inference |
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
docker ps --filter "name=rcao-"

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
   docker network connect rcao-claw_squid-egress rcao-ollama

   # Pull model
   docker compose -f docker/docker-compose.yml exec ollama ollama pull llama3.1

   # Disconnect from internet
   docker network disconnect rcao-claw_squid-egress rcao-ollama
   ```

3. Update `openclaw.json` to reference the new model ID.

## Model Benchmarks

Benchmarks run on **Apple M4 Pro** (14 CPUs, 20 GPU cores, 24 GB RAM) using native Ollama with Metal GPU acceleration. Each prompt was run 3 times and averaged across 4 prompt types (short, medium, coding, reasoning).

### Results (updated 2026-04-10)

| Model | Params | Disk | Avg tok/s | Avg Latency | Cold Start | Quality | Rating |
|-------|--------|------|-----------|-------------|------------|---------|--------|
| **gemma4:e2b** | 12B | 7.2 GB | **105.1** | 10.50s | 4.35s (3.11s load) | 3/3 | ★★★ Excellent |
| qwen3:8b | 8B | 5.2 GB | 45.5 | **3.96s** | 3.59s (2.40s load) | 3/3 | ★★★ Excellent |
| qwen3.5:4b | 4B | 3.4 GB | 38.5 | 6.59s | 11.34s (10.07s load) | 3/3 | ★★★ Excellent |
| qwen3.5:9b | 9B | 6.6 GB | 28.6 | 9.84s | 6.50s (4.53s load) | 3/3 | ★★☆ Good |

### Quality Test Results (2026-04-10)

Beyond speed, we test models on 6 real-world capability categories that reflect daily developer and QA workflows. 58 total points across 15 tests.

| Model | Planning | Code Gen | Bug Detection | Instructions | Communication | Reasoning | Total |
|-------|----------|----------|---------------|--------------|---------------|-----------|-------|
| **gemma4:e2b** | **7/7** | **14/14** | **9/9** | **9/9** | **10/10** | **9/9** | **58/58 (100%)** |
| qwen3:8b | 6/7 | 14/14 | 9/9 | 9/9 | 10/10 | 9/9 | **57/58 (98%)** |
| qwen3.5:4b | **7/7** | **14/14** | **9/9** | **9/9** | **10/10** | **9/9** | **58/58 (100%)** |
| qwen3.5:9b | **7/7** | **14/14** | **9/9** | **9/9** | **10/10** | **9/9** | **58/58 (100%)** |

**Test categories explained:**

| Category | Tests | What It Measures |
|----------|-------|------------------|
| Planning (7 pts) | Feature decomposition, risk identification | Can the model break tasks into steps and spot risks? |
| Code Gen (14 pts) | Function with constraints, test generation, code modification | Can it write code that follows specs, generate tests, modify existing code? |
| Bug Detection (9 pts) | SQL injection, race conditions, error diagnosis | Can it spot security bugs, concurrency issues, and diagnose errors? |
| Instructions (9 pts) | Format constraints, system prompt adherence, safety refusal | Does it follow output formats, obey system prompts, refuse dangerous requests? |
| Communication (10 pts) | PR descriptions, Slack bug reports, diff summarization | Can it write concise, actionable messages for team communication? |
| Reasoning (9 pts) | Tradeoff analysis, bug prioritization, root cause analysis | Can it reason about choices, prioritize, and diagnose production issues? |

### Key Findings

- **gemma4:e2b** dominates throughput at 105.1 tok/s — over 2x faster than qwen3:8b — with perfect 100% quality across all 58 tests. Higher latency (10.50s avg) is driven by longer coding responses, not slower generation. Fast cold start (4.35s). The new top pick for 24GB+ machines.
- **qwen3:8b** has the lowest latency at 3.96s with 98% quality. Best pick when response time matters more than throughput — the 1-point miss was in task decomposition (didn't list all endpoints explicitly).
- **qwen3.5:4b** hits the sweet spot for 16GB RAM laptops — perfect 100% quality, smallest disk (3.4 GB), solid 38.5 tok/s. Recommended default for resource-constrained machines.
- **qwen3.5:9b** also scores 100% quality but is notably slower at 28.6 tok/s. The extra parameters don't add measurable quality on these tests but cost 40% more latency.
- All four models are **Strong** or **Excellent** rated — reliable as daily drivers for developer and QA workflows.

### Recommendation by Hardware

| RAM | Recommended Model | Rationale |
|-----|-------------------|-----------|
| 16 GB | **qwen3.5:4b** | 100% quality, 3.4 GB disk, leaves room for IDE + Docker |
| 18-24 GB | **gemma4:e2b** | 100% quality, 105.1 tok/s, best throughput with Metal GPU |
| 24 GB+ | **gemma4:e2b** | 100% quality, 2x faster than alternatives, 7.2 GB disk |
| 32 GB+ | **qwen3.5:9b** | 100% quality, good for complex reasoning tasks at scale |

### Running Benchmarks

```bash
# Speed benchmarks (latency, throughput, cold start)
./bin/benchmark-models.sh                    # All candidate models
./bin/benchmark-models.sh qwen3:8b           # Specific model
./bin/benchmark-models.sh --installed        # Installed only

# Quality tests (6 capability categories, 15 tests)
./bin/quality-tests.sh                       # Current model from .env
./bin/quality-tests.sh qwen3:8b              # Specific model
./bin/quality-tests.sh --all                 # All candidate models
./bin/quality-tests.sh --category bugs       # Single category
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
docker ps --filter "name=rcao-claw"

# Check health endpoint
curl -v http://localhost:3000/health

# Check container logs
cd docker && docker compose logs openclaw

# Verify port binding
docker port rcao-claw
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
docker exec rcao-claw ls -la /home/openclaw/.ssh/

# Test SSH manually
docker exec rcao-claw ssh -v -i /home/openclaw/.ssh/id_ed25519 \
  openclaw-bot@host.docker.internal "service-status"
```

### Ollama not responding

```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' rcao-ollama

# Check Ollama logs
cd docker && docker compose logs ollama

# Check model is pulled
docker compose -f docker/docker-compose.yml exec ollama ollama list

# Verify network connectivity from openclaw
docker exec rcao-claw curl -s http://ollama:11434/api/tags
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
docker ps --filter "name=rcao-squid"

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
docker stats rcao-claw rcao-ollama rcao-squid

# Check for OOM kills
docker inspect --format='{{.State.OOMKilled}}' rcao-ollama

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
