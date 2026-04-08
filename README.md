# Zupee Claw

<!-- Uncomment when CI is enabled
[![Lint](https://github.com/zupee-labs/zupee-claw/actions/workflows/lint.yml/badge.svg)](https://github.com/zupee-labs/zupee-claw/actions/workflows/lint.yml)
-->
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Secure, air-gapped AI development partner running inside Docker. Uses local LLM inference via Ollama and delegates coding tasks to Claude Code through a locked-down SSH gateway.

## Why Zupee Claw?

Running AI coding assistants on a work machine raises real concerns: unrestricted shell access, network calls to unknown endpoints, accidental data leaks. Zupee Claw solves this by:

- **Air-gapping the AI** inside a Docker container with no direct host access
- **Whitelisting every command** the AI can run on the host via an SSH gateway
- **Running inference locally** with Ollama — your code never leaves the machine
- **Logging everything** for full auditability

The result: an AI dev partner that can read code, write code, run tests, and commit — but literally nothing else.

## How It Works

```
You (browser) -> localhost:3000 (Claw Web UI)
                      |
                      v
              Claw Gateway (Docker) --> Ollama LLM (Docker)
                      |
                      | SSH (whitelisted commands only)
                      v
              Host: git-status, git-pull, run-tests, run-claude
                      |
                      v
              Claude Code (locked to $WORKSPACE_DIR/$REPO)
```

The AI operates through a two-layer sandbox:
1. **Docker container** — process and filesystem isolation
2. **SSH ForceCommand gateway** — only pre-approved scripts can execute on the host

See [docs/architecture.md](docs/architecture.md) for the full architecture, security layers, and directory structure.

## Prerequisites

- Docker & Docker Compose
- macOS or Linux
- 16 GB RAM minimum (8 GB for Ollama + 2 GB for Claw)
- SSH server running on the host

## Quickstart

```bash
# 1. Clone
git clone https://github.com/zupee-labs/zupee-claw.git
cd zupee-claw

# 2. Configure environment
cp .env.example .env
# Edit .env — set WORKSPACE_DIR, REPO, OLLAMA_MODEL

# 3. Run setup (creates SSH keys, host user, copies configs)
./setup.sh

# 4. Start services
cd docker && docker compose up -d --build
```

## Configuration

All settings live in `.env` (copied from `.env.example`):

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW_VERSION` | `2026.4.2` | Pinned Claw version |
| `REPO` | `my-project` | Default repo name under workspace dir |
| `WORKSPACE_DIR` | `~/workspace` | Root directory where your repos live |
| `OLLAMA_MODEL` | `qwen3.5` | Ollama model for local inference |

## Daily Usage

```bash
# Start
cd docker && docker compose up -d

# Open Web UI
open http://localhost:3000

# Check status
ssh openclaw-bot@localhost "service-status"

# Stop
cd docker && docker compose down
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

Default repo is set in `.env`. All commands accept an optional `[repo]` override.

## Adding Custom Commands

1. Create `bin/<command-name>.sh` following existing script patterns
2. Add `<command-name>` to `bin/allowed-commands.conf`
3. The SSH gateway will automatically route the new command

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Troubleshooting

**Containers won't start:**
```bash
docker compose -f docker/docker-compose.yml config  # Validate compose file
docker compose -f docker/docker-compose.yml logs     # Check logs
```

**SSH gateway rejects commands:**
```bash
# Check the gateway log for denied commands
tail -f logs/gateway.log
# Verify the command is in allowed-commands.conf
cat bin/allowed-commands.conf
```

**Ollama model not responding:**
```bash
# Pull the model manually
docker compose -f docker/docker-compose.yml exec ollama ollama pull qwen3.5
# Check Ollama status
docker compose -f docker/docker-compose.yml exec ollama ollama list
```

**Claude Code not working:**
```bash
# Check Claude execution log
tail -f logs/claude.log
# Verify workspace exists
ls -la $WORKSPACE_DIR/$REPO
```

## Teardown

```bash
./cleanup.sh
```

This removes containers, images, volumes, SSH keys, and the host user. Agent data is optionally preserved.

## Verification

After running `setup.sh`, verify everything works:

```bash
# 1. Check containers are running
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep zupee

# 2. Validate Docker Compose config
docker compose -f docker/docker-compose.yml config --quiet

# 3. Check Web UI health
curl -sf http://localhost:3000/health

# 4. Verify SSH gateway
ssh openclaw-bot@localhost "service-status"

# 5. Check ShellCheck passes
shellcheck bin/*.sh setup.sh cleanup.sh

# 6. Verify no personal data leaked
grep -ri "your-real-name" . --include='*.md' --include='*.sh' --include='*.yml'

# 7. Validate all JSON files
find . -name '*.json' -not -path './.git/*' -exec python3 -c "import json,sys; json.load(open(sys.argv[1]))" {} \;
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, conventions, and PR guidelines.

## License

[MIT](LICENSE)
