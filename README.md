# Zupee Claw

Secure, air-gapped AI development partner running inside Docker on an office laptop. Uses local Qwen 3.5 inference via Ollama and delegates coding tasks to Claude Code through a locked-down SSH gateway.

## Prerequisites

- Docker & Docker Compose
- macOS or Linux
- 16 GB RAM minimum (8 GB for Ollama + 2 GB for Claw)

## Quickstart

```bash
# 1. Run setup (creates SSH keys, host user, copies configs)
./setup.sh

# 2. Copy and configure environment
cp .env.example .env

# 3. Start services
cd docker && docker compose up -d --build
```

## Daily Usage

```bash
# Start
make up

# Open Web UI
open http://localhost:3000

# Check status
make status

# View logs
make logs

# Stop
make down
```

## Available Commands

All commands run via SSH gateway from the Claw container to the host.

| Command | Purpose |
|---------|---------|
| `git-status [repo]` | Check working tree |
| `git-pull [repo]` | Pull latest with rebase |
| `run-tests [repo]` | Run test suite |
| `run-claude <prompt> [repo]` | Coding tasks (25 turns, $10 cap) |
| `service-status` | Host health + list repos |

## Slack Integration

Claw connects to Slack via its native plugin using Socket Mode (real-time WebSocket). Traffic is routed through a Squid proxy that only allows `*.slack.com` and `*.slack-edge.com`. See [docs/slack-integration.md](docs/slack-integration.md) for setup.

Default repo is set in `.env`. All commands accept an optional `[repo]` override.

## Architecture

See [PLAN.md](PLAN.md) for the full architecture diagram, security layers, and setup details.
