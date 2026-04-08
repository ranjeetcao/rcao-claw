---
globs:
  - "bin/*.sh"
  - "setup.sh"
  - "cleanup.sh"
  - "docker/entrypoint.sh"
---

# Shell Script Conventions

## Header

Every script starts with:

```bash
#!/bin/bash
set -euo pipefail
```

## Workspace Resolution

Scripts in `bin/` source `workspace-env.sh` for workspace path resolution. This provides consistent directory references across all gateway scripts.

## Environment File Parsing

Parse `.env` files with `grep`/`cut` — for example:

```bash
value=$(grep '^KEY=' .env | cut -d'=' -f2-)
```

**NEVER** use `source .env`. Sourcing an env file executes arbitrary code, which is a code injection vector.

## Input Validation

Reject inputs that contain any of the following:

- Shell metacharacters: ``; | & $ ` \ ( ) { } < >``
- Path traversal sequences: `..`
- Absolute paths in repo/workspace names

## Logging

- Use **ISO 8601 timestamps** in all log entries.
- Log to `~/openclaw/logs/<script>.log` (one log file per script).

## Colored Output Functions

Use the standard helper functions for user-facing output:

- `info()` — green text for informational messages.
- `warn()` — yellow text for warnings.
- `error()` — red text for error messages.
- `step()` — green header for major steps.

## Interactive Prompts

- Use `read -rp` for interactive prompts.
- Always **default to No** — require explicit `y` or `Y` to proceed.

## General Shell Best Practices

- **Quote all variable expansions**: `"$VAR"` not `$VAR`.
- **Use `[[ ]]`** for conditionals, not `[ ]`.
- **ShellCheck must pass**: Run `shellcheck bin/*.sh setup.sh cleanup.sh` before committing.
