#!/bin/bash
set -euo pipefail

# SSH ForceCommand gateway - validates all incoming commands against allowlist
# Every SSH session hits this script regardless of what command was requested

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="$SCRIPT_DIR/allowed-commands.conf"
LOGFILE="$HOME/openclaw/logs/gateway.log"

# Sanitize log data: strip newlines and non-printable characters
log() {
    local msg
    msg="$(printf '%s' "$*" | tr -d '\n' | tr -cd '[:print:]')"
    echo "[$(date -Iseconds)] [$$] $msg" >> "$LOGFILE"
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Rate limiting: max 30 commands per minute
# Uses mkdir-based locking (portable, works on macOS and Linux without flock)
RATE_DIR="$HOME/openclaw"
mkdir -p "$RATE_DIR"
RATE_MAIN="$RATE_DIR/.rate-limit"
RATE_TMP="$RATE_DIR/.rate-limit.tmp.$$"
RATE_LOCK="$RATE_DIR/.rate-limit.lock"
RATE_WINDOW=60
RATE_LIMIT=30
_now=$(date +%s)

# Acquire lock (mkdir is atomic on all platforms)
_lock_acquired=false
for _i in 1 2 3; do
    if mkdir "$RATE_LOCK" 2>/dev/null; then
        _lock_acquired=true
        break
    fi
    # Remove stale lock (older than 5 seconds)
    if [[ -d "$RATE_LOCK" ]]; then
        _lock_age=$(( _now - $(stat -f %m "$RATE_LOCK" 2>/dev/null || stat -c %Y "$RATE_LOCK" 2>/dev/null || echo "$_now") ))
        if [[ $_lock_age -gt 5 ]]; then
            rmdir "$RATE_LOCK" 2>/dev/null || true
        fi
    fi
done

if [[ "$_lock_acquired" == "true" ]]; then
    # Clean entries older than RATE_WINDOW
    if [[ -f "$RATE_MAIN" ]]; then
        awk -v cutoff=$((_now - RATE_WINDOW)) '$1 > cutoff' "$RATE_MAIN" > "$RATE_TMP" 2>/dev/null || true
        mv "$RATE_TMP" "$RATE_MAIN" 2>/dev/null || true
        _count=$(wc -l < "$RATE_MAIN" 2>/dev/null || echo "0")
        _count=$(echo "$_count" | tr -d ' ')
        if [[ $_count -ge $RATE_LIMIT ]]; then
            rmdir "$RATE_LOCK" 2>/dev/null || true
            log "DENIED: rate limit exceeded ($_count commands in ${RATE_WINDOW}s)"
            echo "ERROR: Rate limit exceeded. Try again later."
            exit 1
        fi
    fi
    echo "$_now" >> "$RATE_MAIN"
    rmdir "$RATE_LOCK" 2>/dev/null || true
else
    log "DENIED: rate limiter busy"
    echo "ERROR: Rate limiter busy. Try again."
    exit 1
fi

# SSH_ORIGINAL_COMMAND is set by sshd when ForceCommand is active
if [[ -z "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    log "DENIED: empty command (interactive shell attempt)"
    echo "ERROR: Interactive shell not permitted. Use: ssh <user>@host <command> [args...]"
    exit 1
fi

# Extract command name (first word) and arguments
CMD_NAME="${SSH_ORIGINAL_COMMAND%% *}"
CMD_ARGS="${SSH_ORIGINAL_COMMAND#"$CMD_NAME"}"
CMD_ARGS="${CMD_ARGS# }"  # trim leading space

# Block path traversal, absolute paths, and slashes in command name
if [[ "$CMD_NAME" == *".."* ]] || [[ "$CMD_NAME" == /* ]] || [[ "$CMD_NAME" == *"/"* ]]; then
    log "DENIED: path traversal attempt: $SSH_ORIGINAL_COMMAND"
    echo "ERROR: Invalid command"
    exit 1
fi

# Block shell metacharacters in command name
if [[ "$CMD_NAME" =~ [\;\|\&\$\`\\\(\)\{\}\<\>] ]]; then
    log "DENIED: shell metacharacters in command: $SSH_ORIGINAL_COMMAND"
    echo "ERROR: Invalid command"
    exit 1
fi

# Block shell metacharacters in arguments
if [[ -n "$CMD_ARGS" ]] && [[ "$CMD_ARGS" =~ [\;\|\&\$\`\\\(\)\{\}\<\>] ]]; then
    log "DENIED: shell metacharacters in arguments: $SSH_ORIGINAL_COMMAND"
    echo "ERROR: Invalid arguments"
    exit 1
fi

# Check allowlist (literal match, not regex)
if ! grep -Fqx "$CMD_NAME" "$ALLOWLIST" 2>/dev/null; then
    log "DENIED: command not in allowlist: $SSH_ORIGINAL_COMMAND"
    echo "ERROR: Command '$CMD_NAME' is not permitted"
    exit 1
fi

# Verify script exists and is executable
SCRIPT="$SCRIPT_DIR/${CMD_NAME}.sh"
if [[ ! -x "$SCRIPT" ]]; then
    log "DENIED: script not found or not executable: $SCRIPT"
    echo "ERROR: Command '$CMD_NAME' is not available"
    exit 1
fi

# Execute allowed command (quoted to prevent glob expansion and word splitting)
log "ALLOWED: $SSH_ORIGINAL_COMMAND"
exec "$SCRIPT" "$CMD_ARGS"
