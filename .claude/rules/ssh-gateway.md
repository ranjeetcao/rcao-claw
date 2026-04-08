---
globs:
  - "bin/*.sh"
  - "config/sshd_*"
  - "config/authorized_keys"
---

# SSH Gateway Security Model

## Architecture

`ssh-gateway.sh` is the **ForceCommand** entry point for ALL SSH sessions into the openclaw container. Every command from the AI agent passes through this gateway before execution.

## Command Validation

- Commands are validated against `bin/allowed-commands.conf` using **literal match** (not regex).
- The gateway resolves a command name to `bin/<name>.sh` and executes it.
- Only exact names listed in the allowlist are permitted. No glob patterns, no path components.

## Input Validation

All inputs are checked before any command runs. The gateway **blocks**:

- Path traversal sequences (`..`)
- Absolute paths
- Shell metacharacters (``; | & $ ` \ ( ) { } < >``)

## Rate Limiting

- Maximum **30 commands per minute** per session.
- Exceeding the limit results in a DENIED log entry and a non-zero exit code.

## Logging

- **All commands** (both allowed and denied) are logged to `~/openclaw/logs/gateway.log`.
- Log entries include timestamps, the command requested, and whether it was ALLOWED or DENIED.

## Adding a New Command

1. Create `bin/<name>.sh` with `set -euo pipefail` at the top.
2. Add `<name>` to `allowed-commands.conf` (one entry per line, exact name only).
3. Test the command via SSH to confirm the gateway routes it correctly.

## NEVER Do the Following

- Allow glob patterns in the allowlist.
- Skip or bypass input validation.
- Disable logging for any command.
- Allow interactive shell access (the ForceCommand prevents this by design).
