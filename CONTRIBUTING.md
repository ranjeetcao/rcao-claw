# Contributing to Zupee Claw

Thanks for your interest in contributing! This guide covers how to set up the project and submit changes.

## Development Setup

1. **Clone the repo:**
   ```bash
   git clone https://github.com/zupee-labs/zupee-claw.git
   cd zupee-claw
   ```

2. **Copy environment config:**
   ```bash
   cp .env.example .env
   # Edit .env to set WORKSPACE_DIR, REPO, OLLAMA_MODEL
   ```

3. **Run setup:**
   ```bash
   ./setup.sh
   ```

4. **Start services:**
   ```bash
   cd docker && docker compose up -d --build
   ```

## Project Structure

- `bin/` — Whitelisted shell scripts (mounted read-only into Docker)
- `config/` — SSH keys, host SSH config, Claude Code settings
- `openclaw-home/` — Agent workspace (personality, memory, sessions)
- `docker/` — Dockerfile, docker-compose.yml, entrypoint
- `docs/` — Architecture documentation
- `logs/` — Audit logs (gitignored)

## Making Changes

### Shell Scripts

All scripts in `bin/` follow these conventions:
- `set -euo pipefail` at the top
- Source `workspace-env.sh` for workspace resolution
- Validate inputs (reject shell metacharacters)
- Log actions to `~/openclaw/logs/`

Run ShellCheck before submitting:
```bash
shellcheck bin/*.sh setup.sh cleanup.sh
```

### Adding a New Host Command

1. Create `bin/<command-name>.sh` following existing patterns
2. Add `<command-name>` to `bin/allowed-commands.conf`
3. Test via the SSH gateway

### Agent Workspace Files

Files in `openclaw-home/workspace/` define the agent's personality and instructions. See `docs/architecture.md` for what each file does.

## Pull Request Guidelines

- Create a feature branch from `main`
- Use conventional commits: `feat:`, `fix:`, `docs:`, `chore:`
- Keep PRs focused — one concern per PR
- Ensure ShellCheck passes on all `.sh` files
- Test the full setup/cleanup cycle if you changed `setup.sh` or `cleanup.sh`
- Fill out the PR template

## Reporting Issues

Use the GitHub issue templates for bug reports and feature requests.

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
