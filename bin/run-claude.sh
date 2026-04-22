#!/bin/bash
set -euo pipefail

# Launch Claude Code with locked-down permissions
# Usage: run-claude <prompt> [repo-name]
# Defaults to .env WORKSPACE
#
# Permissions co-source-of-truth: config/claude-settings.json
# Keep --allowedTools / --disallowedTools in sync with that file.

# Find claude CLI — check common install locations
CLAUDE_BIN=""
for _p in /usr/local/bin/claude /opt/homebrew/bin/claude "$HOME/.local/bin/claude"; do
    if [[ -x "$_p" ]]; then
        CLAUDE_BIN="$_p"
        break
    fi
done
# Search all users' .local/bin as fallback
if [[ -z "$CLAUDE_BIN" ]]; then
    CLAUDE_BIN=$(find /Users/*/.local/bin/claude 2>/dev/null | head -1 || true)
fi
if [[ -z "$CLAUDE_BIN" ]]; then
    echo "ERROR: claude CLI not found. Install from https://claude.ai/download"
    exit 1
fi

LOGFILE="$HOME/openclaw/logs/claude.log"

if [[ $# -lt 1 ]]; then
    echo "Usage: run-claude <prompt> [repo-name]"
    exit 1
fi

PROMPT="$1"

source "$(dirname "${BASH_SOURCE[0]}")/workspace-env.sh" "${2:-}"

# Reject excessively long prompts
if [[ ${#PROMPT} -gt 8000 ]]; then
    echo "[$(date -Iseconds)] DENIED: prompt too long (${#PROMPT} chars)" >> "$LOGFILE"
    echo "ERROR: Prompt exceeds 8000 character limit (actual: ${#PROMPT} chars). Break into smaller prompts."
    exit 1
fi

echo "[$(date -Iseconds)] CLAUDE START: dir=$WORKDIR prompt=${PROMPT:0:100}..." >> "$LOGFILE"

# Claude Code uses macOS Keychain for OAuth, which isn't available in SSH sessions.
# Use apiKeyHelper to read the token from .credentials-cache instead.
# setup.sh creates this helper and refreshes the cache from Keychain at setup time.
# Build a combined settings file: auth helper + permission overrides.
# This overrides the target repo's .claude/settings.json so our lockdown
# rules apply and file creation (Write, mkdir) is allowed for docs/.
AUTH_HELPER="$HOME/openclaw/claude-auth-helper.sh"
CLAW_SETTINGS_FILE="$HOME/openclaw/claude-run-settings.json"
CLAW_SETTINGS=""

_AUTH_LINE=""
if [[ -f "$AUTH_HELPER" ]]; then
    _AUTH_LINE="\"apiKeyHelper\": \"$AUTH_HELPER\","
fi

cat > "$CLAW_SETTINGS_FILE" << SETTINGS_EOF
{
  $_AUTH_LINE
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "Bash(npm test *)",
      "Bash(npm run *)",
      "Bash(npm install *)",
      "Bash(npm ci)",
      "Bash(pnpm *)",
      "Bash(git diff *)",
      "Bash(git log *)",
      "Bash(git status)",
      "Bash(git show *)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git branch *)",
      "Bash(git checkout *)",
      "Bash(git stash *)",
      "Bash(git remote *)",
      "Bash(git push *)",
      "Bash(gh pr create *)",
      "Bash(gh pr view *)",
      "Bash(node src/*)",
      "Bash(node scripts/*)",
      "Bash(node dist/*)",
      "Bash(ls *)",
      "Bash(mkdir *)",
      "Bash(rm *.ts)",
      "Bash(rm *.js)",
      "Bash(rm *.json)",
      "Bash(rm *.md)",
      "Bash(rm *.css)",
      "Bash(rm *.html)",
      "Bash(wc *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(sort *)",
      "Bash(which *)"
    ],
    "deny": [
      "Bash(node -e *)",
      "Bash(npx *)",
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(rm -rf *)",
      "Bash(rm -r *)",
      "Bash(ssh *)",
      "Bash(sudo *)",
      "Bash(python *)",
      "Bash(python3 *)",
      "Bash(bash -c *)",
      "Bash(sh -c *)",
      "Bash(docker *)",
      "Bash(git push origin main)",
      "Bash(git push -f *)",
      "Bash(git rebase *)",
      "Bash(git reset *)",
      "Bash(git merge *)",
      "Bash(git config *)",
      "WebFetch",
      "WebSearch"
    ]
  }
}
SETTINGS_EOF
CLAW_SETTINGS="--settings $CLAW_SETTINGS_FILE"

cd "$WORKDIR"

# System prompt establishes Claw's identity and the backlog workflow.
# This is prepended to the repo's own CLAUDE.md context.
SCRIPT_BASE="$(dirname "${BASH_SOURCE[0]}")/.."
PERSONALITY_DIR="$SCRIPT_BASE/personality"
SYSTEM_PROMPT=""
if [[ -d "$PERSONALITY_DIR" ]]; then
    # Find the role from the installed personality (check which SOUL.md exists)
    for _role_dir in "$PERSONALITY_DIR"/*/; do
        _role=$(basename "$_role_dir")
        [[ "$_role" == "shared" ]] && continue
        if [[ -f "$_role_dir/SOUL.md" ]]; then
            SYSTEM_PROMPT="$(cat "$PERSONALITY_DIR/shared/IDENTITY.md" "$_role_dir/SOUL.md" "$_role_dir/AGENTS.md" 2>/dev/null)"
            break
        fi
    done
fi

# shellcheck disable=SC2086
"$CLAUDE_BIN" -p "$PROMPT" \
  $CLAW_SETTINGS \
  ${SYSTEM_PROMPT:+--append-system-prompt "$SYSTEM_PROMPT"} \
  --permission-mode dontAsk \
  --max-turns 25 \
  --max-budget-usd 10.00 \
  2>&1 | tee -a "$LOGFILE"

EXIT_CODE=${PIPESTATUS[0]}
echo "[$(date -Iseconds)] CLAUDE END: exit=$EXIT_CODE" >> "$LOGFILE"
exit $EXIT_CODE
