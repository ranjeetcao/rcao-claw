# Tools

## Two Ways to Access the Codebase

### 1. Direct Access (for most tasks)

Your workspace is mounted at `/workspace` inside the container. Use OpenClaw's built-in tools:

| Tool | Example | Use for |
|------|---------|---------|
| `read` | Read `/workspace/package.json` | View file contents |
| `write` | Write to `/workspace/docs/PLAN.md` | Create new files |
| `edit` | Edit `/workspace/src/app.ts` | Modify existing files |
| `exec` | `ls /workspace/` | List directories, run git, grep |

**Examples:**
- List services: `exec ls /workspace/`
- Read a file: `read /workspace/README.md`
- Git status: `exec cd /workspace && git status`
- Search code: `exec grep -r "authGuard" /workspace/api-gateway/src/`
- Git log: `exec cd /workspace && git log --oneline -10`

### 2. Claude Code via SSH (for complex coding tasks)

For tasks needing deep code understanding, refactoring, or multi-file changes,
use Claude Code on the host via SSH:

```
exec ssh -i /home/openclaw/.ssh/id_ed25519 -o StrictHostKeyChecking=no ranjeet@host.docker.internal "run-claude <prompt>"
```

**Examples:**
- Code review: `run-claude review the auth flow in user-service`
- Write tests: `run-claude write unit tests for the booking service`
- Refactor: `run-claude refactor the error handling in api-gateway`
- Create PR: `run-claude create a feature branch and fix the rate limiter`

**Limits:** 50 turns max, $10 budget per run-claude invocation.

### When to Use Which

| Task | Use |
|------|-----|
| Read files, check git status, list dirs | Direct (read/exec) |
| Answer questions about code | Direct (read) |
| Search for patterns | Direct (exec grep) |
| Simple edits (typo, config change) | Direct (edit) |
| Create proposals/plans in docs/ | Direct (write) |
| Complex refactoring | SSH → run-claude |
| Write tests following project patterns | SSH → run-claude |
| Multi-file code changes | SSH → run-claude |
| Code review with deep analysis | SSH → run-claude |

## Slack

Connected via Socket Mode. Send messages, read channels, react.
All Slack traffic proxied through Squid (HTTPS only, *.slack.com).
