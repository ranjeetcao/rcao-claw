---
globs:
  - "bin/run-claude.sh"
  - "config/claude-settings.json"
---

# Claude Code Lockdown

## Two Sources of Truth

Claude Code restrictions are enforced in two places that **must stay in sync**:

1. **`bin/run-claude.sh`** — CLI flags (`--allowedTools`, `--disallowedTools`, `--permission-mode dontAsk`).
2. **`config/claude-settings.json`** — Persistent deny rules for the settings file inside the container.

Both must deny the same tools. If one allows something the other blocks, behavior is unpredictable.

## Blocked Tool Categories

| Category        | Examples                                      |
|-----------------|-----------------------------------------------|
| Network         | `curl`, `wget`, `ssh`                         |
| System          | `sudo`, `docker`, `mount`                     |
| Interpreters    | `python`, `ruby`, `perl`                      |
| Shell escape    | `bash -c`, `sh -c`, `eval`, `exec`            |
| Bulk delete     | `rm -rf`, `rm -r`                             |
| Destructive git | `push`, `rebase`, `reset`, `merge`            |

## Allowed Tools

- File operations: `Read`, `Edit`, `Write`, `Glob`, `Grep`
- Safe npm commands (no `npx`)
- Read-only git operations
- `node` for running specific files (but not `node -e` or `npx`)

## Execution Limits

- `--max-turns 25` — prevents runaway agent loops.
- `--max-budget-usd 10.00` — prevents cost overruns.
- Prompt length limit: **8000 characters**.

## NEVER Do the Following

- Remove `ssh`, `curl`, `sudo`, or `docker` from the deny list.
- Raise the budget cap above **$50**.
- Allow `WebFetch` or `WebSearch` tools.
- Allow `node -e` or `npx` execution.
