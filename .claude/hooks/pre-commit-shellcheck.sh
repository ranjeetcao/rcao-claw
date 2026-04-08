#!/bin/bash
# pre-commit-shellcheck.sh
# Claude Code PreToolUse hook for the Bash tool.
# Runs shellcheck on staged .sh files before git commit.
#
# Input:  JSON on stdin with {"tool_name":"Bash","tool_input":{"command":"..."}}
# Output: exit 0 to allow, exit 2 with shellcheck errors on stdout to block.

set -euo pipefail

# Fail-closed: if the hook crashes, block the command rather than silently allow
trap 'echo "BLOCKED: ShellCheck hook crashed unexpectedly"; exit 2' ERR

# ---------------------------------------------------------------------------
# 1. Read tool input and extract the command
# ---------------------------------------------------------------------------
INPUT="$(cat)"

if ! command -v python3 &>/dev/null; then
  echo "BLOCKED: python3 is required for ShellCheck hook but not found"
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
# 3. Check if shellcheck is installed
# ---------------------------------------------------------------------------
if ! command -v shellcheck &>/dev/null; then
  echo "shellcheck is not installed; skipping shell script linting." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Get staged .sh files
# ---------------------------------------------------------------------------
STAGED_SH_FILES="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.sh$' || true)"

if [[ -z "$STAGED_SH_FILES" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Run shellcheck on each staged file
# ---------------------------------------------------------------------------
ERRORS=""
FAILED=false

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  # Run shellcheck on the staged version by extracting it to a temp file
  TMPFILE="$(mktemp "/tmp/shellcheck-staged-XXXXXX.sh")"
  # shellcheck disable=SC2064
  trap "rm -f '$TMPFILE'" EXIT

  git show ":${file}" > "$TMPFILE" 2>/dev/null || continue

  OUTPUT="$(shellcheck -f gcc "$TMPFILE" 2>&1 || true)"

  if [[ -n "$OUTPUT" ]]; then
    FAILED=true
    # Replace temp file path with actual file name in output
    CLEANED="$(echo "$OUTPUT" | sed "s|${TMPFILE}|${file}|g")"
    ERRORS="${ERRORS}--- ${file} ---"$'\n'"${CLEANED}"$'\n'$'\n'
  fi

  rm -f "$TMPFILE"
done <<< "$STAGED_SH_FILES"

# ---------------------------------------------------------------------------
# 6. Report results
# ---------------------------------------------------------------------------
if [[ "$FAILED" == true ]]; then
  echo "BLOCKED: shellcheck found issues in staged shell scripts!"
  echo ""
  echo "$ERRORS"
  echo "Fix the issues above before committing."
  exit 2
fi

exit 0
