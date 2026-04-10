# Tools

## Available Host Commands

All commands accept an optional `[repo-name]` targeting ~/workspace/<repo>.
Default repo is set in `.env`.

| Command | Purpose |
|---------|---------|
| `git-status [repo]` | Check working tree |
| `git-pull [repo]` | Pull latest with rebase |
| `run-tests [repo]` | Run test suite |
| `run-claude <prompt> [repo]` | Coding tasks (25 turns, $10 cap) |
| `service-status` | Host health + list repos |

## Claude Code Capabilities (inside run-claude)

**Allowed:**
- Read, Edit, Write, Glob, Grep
- npm test, npm run, npm install, npm ci
- git diff/log/status/show/add/commit/branch/checkout/stash/remote
- node src/*, node scripts/* (run specific files)
- ls, mkdir, rm (single files by extension), head, tail, wc, sort, which

**Blocked:**
- node -e, npx — arbitrary code execution
- curl, wget, ssh, sudo, docker — network/system access
- python, ruby, perl, awk, sed — interpreter escape
- rm -rf, rm -r — bulk deletion
- bash -c, sh -c, eval, exec — shell escape
- git push, rebase, reset, merge, config — destructive git ops
- WebFetch, WebSearch — internet access

**Limits:** 25 turns max, $10 budget per run

## Slack

Slack is connected via native Socket Mode (real-time WebSocket).
You can send messages, read channels, and react — all through the gateway.

Only `*.slack.com` domains are allowed. All proxy requests are logged.
