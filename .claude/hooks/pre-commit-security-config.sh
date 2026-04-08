#!/bin/bash
# pre-commit-security-config.sh
# Claude Code PreToolUse hook for the Bash tool.
# Validates that security-critical configuration has not been weakened
# in staged files before git commit.
#
# Input:  JSON on stdin with {"tool_name":"Bash","tool_input":{"command":"..."}}
# Output: exit 0 to allow, exit 2 with descriptive message on stdout to block.

set -euo pipefail

# Fail-closed: if the hook crashes, block the command rather than silently allow
trap 'echo "BLOCKED: Security config hook crashed unexpectedly"; exit 2' ERR

# ---------------------------------------------------------------------------
# 1. Read tool input and extract the command
# ---------------------------------------------------------------------------
INPUT="$(cat)"

if ! command -v python3 &>/dev/null; then
  echo "BLOCKED: python3 is required for security config hook but not found"
  exit 2
fi

COMMAND="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))")"

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Only act on git commit commands
# ---------------------------------------------------------------------------
if ! echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Get list of staged files
# ---------------------------------------------------------------------------
STAGED_FILES="$(git diff --cached --name-only 2>/dev/null || true)"

if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

VIOLATIONS=""

# ---------------------------------------------------------------------------
# 4. Check docker/docker-compose.yml
# ---------------------------------------------------------------------------
if echo "$STAGED_FILES" | grep -qE '^docker/docker-compose\.yml$'; then
  COMPOSE_CONTENT="$(git show ':docker/docker-compose.yml' 2>/dev/null || true)"

  if [[ -n "$COMPOSE_CONTENT" ]]; then
    # 4a. Port bindings must use 127.0.0.1, not 0.0.0.0
    # Look for port mappings that use 0.0.0.0 or have no bind address (bare port:port)
    if echo "$COMPOSE_CONTENT" | grep -qE '^\s*-\s*"0\.0\.0\.0:'; then
      VIOLATIONS="${VIOLATIONS}[docker-compose.yml] SECURITY REGRESSION: Port binding uses 0.0.0.0 instead of 127.0.0.1"$'\n'
      VIOLATIONS="${VIOLATIONS}  All port bindings must be localhost-only (127.0.0.1:PORT:PORT)"$'\n'$'\n'
    fi

    # Also catch bare port bindings without any IP (e.g., "3000:3000" without 127.0.0.1)
    if echo "$COMPOSE_CONTENT" | grep -E '^\s*-\s*"[0-9]+:[0-9]+"' | grep -vqE '127\.0\.0\.1'; then
      VIOLATIONS="${VIOLATIONS}[docker-compose.yml] SECURITY REGRESSION: Port binding missing 127.0.0.1 bind address"$'\n'
      VIOLATIONS="${VIOLATIONS}  Bare port bindings (PORT:PORT) expose to all interfaces. Use 127.0.0.1:PORT:PORT"$'\n'$'\n'
    fi

    # 4b. Networks must have internal: true
    # Check that 'internal: true' is present for network definitions
    # Count network blocks and internal: true occurrences
    NETWORK_COUNT="$(echo "$COMPOSE_CONTENT" | grep -cE '^\s{2}\w.*:$' | tail -1 || echo "0")"
    if ! echo "$COMPOSE_CONTENT" | grep -qE '^\s+internal:\s+true'; then
      VIOLATIONS="${VIOLATIONS}[docker-compose.yml] SECURITY REGRESSION: Network missing 'internal: true'"$'\n'
      VIOLATIONS="${VIOLATIONS}  All Docker networks must be internal-only to prevent outbound internet access"$'\n'$'\n'
    fi

    # 4c. Must not contain privileged: true
    if echo "$COMPOSE_CONTENT" | grep -qE '^\s+privileged:\s+true'; then
      VIOLATIONS="${VIOLATIONS}[docker-compose.yml] SECURITY REGRESSION: Container has 'privileged: true'"$'\n'
      VIOLATIONS="${VIOLATIONS}  Privileged mode gives container full host access. This must never be enabled."$'\n'$'\n'
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. Check config/claude-settings.json
# ---------------------------------------------------------------------------
if echo "$STAGED_FILES" | grep -qE '^config/claude-settings\.json$'; then
  SETTINGS_CONTENT="$(git show ':config/claude-settings.json' 2>/dev/null || true)"

  if [[ -n "$SETTINGS_CONTENT" ]]; then
    # Required deny list entries
    REQUIRED_DENY_PATTERNS=(
      "ssh"
      "curl"
      "sudo"
      "docker"
      "rm -rf"
    )

    for pattern in "${REQUIRED_DENY_PATTERNS[@]}"; do
      # Check that the deny list contains a Bash() entry for each pattern
      if ! echo "$SETTINGS_CONTENT" | grep -qF "Bash(${pattern}"; then
        VIOLATIONS="${VIOLATIONS}[claude-settings.json] SECURITY REGRESSION: Missing '${pattern}' in deny list"$'\n'
        VIOLATIONS="${VIOLATIONS}  The Claude settings must deny Bash(${pattern} *) to prevent security bypass"$'\n'$'\n'
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# 6. Check bin/run-claude.sh (or any run-claude.sh)
# ---------------------------------------------------------------------------
RUN_CLAUDE_STAGED=""
if echo "$STAGED_FILES" | grep -qE 'run-claude\.sh$'; then
  RUN_CLAUDE_STAGED="$(echo "$STAGED_FILES" | grep -E 'run-claude\.sh$' | head -1)"
fi

if [[ -n "$RUN_CLAUDE_STAGED" ]]; then
  RUN_CLAUDE_CONTENT="$(git show ":${RUN_CLAUDE_STAGED}" 2>/dev/null || true)"

  if [[ -n "$RUN_CLAUDE_CONTENT" ]]; then
    if ! echo "$RUN_CLAUDE_CONTENT" | grep -qF -- '--disallowedTools'; then
      VIOLATIONS="${VIOLATIONS}[${RUN_CLAUDE_STAGED}] SECURITY REGRESSION: Missing --disallowedTools flag"$'\n'
      VIOLATIONS="${VIOLATIONS}  run-claude.sh must include --disallowedTools to enforce tool restrictions"$'\n'$'\n'
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 7. Report results
# ---------------------------------------------------------------------------
if [[ -n "$VIOLATIONS" ]]; then
  echo "BLOCKED: Security configuration regression detected!"
  echo ""
  echo "The following security checks failed:"
  echo ""
  echo "$VIOLATIONS"
  echo "These security controls protect the air-gapped environment."
  echo "If these changes are intentional, they require explicit security review."
  exit 2
fi

exit 0
