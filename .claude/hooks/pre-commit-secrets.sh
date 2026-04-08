#!/bin/bash
# pre-commit-secrets.sh
# Claude Code PreToolUse hook for the Bash tool.
# Scans staged files for accidentally committed secrets before git commit/add.
#
# Input:  JSON on stdin with {"tool_name":"Bash","tool_input":{"command":"..."}}
# Output: exit 0 to allow, exit 2 with reason on stdout to block.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Read tool input and extract the command
# ---------------------------------------------------------------------------
INPUT="$(cat)"
COMMAND="$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || true)"

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Only act on git commit / git add commands
# ---------------------------------------------------------------------------
IS_COMMIT=false
IS_ADD=false

if echo "$COMMAND" | grep -qE '^\s*git\s+commit\b'; then
  IS_COMMIT=true
fi
if echo "$COMMAND" | grep -qE '^\s*git\s+add\b'; then
  IS_ADD=true
fi

if [[ "$IS_COMMIT" == false && "$IS_ADD" == false ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Get list of staged files (for commit) or files about to be added
# ---------------------------------------------------------------------------
STAGED_FILES=""

if [[ "$IS_COMMIT" == true ]]; then
  STAGED_FILES="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)"
fi

if [[ "$IS_ADD" == true ]]; then
  # For git add, extract the paths from the command and check them
  # Also check what is currently staged
  STAGED_FILES="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)"

  # Extract file args from the git add command (everything after 'git add')
  ADD_ARGS="$(echo "$COMMAND" | sed -E 's/^\s*git\s+add\s+//')"

  # If adding specific files, scan those too
  if [[ -n "$ADD_ARGS" && "$ADD_ARGS" != "." && "$ADD_ARGS" != "-A" ]]; then
    for f in $ADD_ARGS; do
      # Skip flags
      if [[ "$f" == -* ]]; then continue; fi
      if [[ -f "$f" ]]; then
        STAGED_FILES="$STAGED_FILES"$'\n'"$f"
      fi
    done
  elif [[ "$ADD_ARGS" == "." || "$ADD_ARGS" == "-A" ]]; then
    # git add . or git add -A: scan all modified/new files
    ALL_FILES="$(git diff --name-only 2>/dev/null || true)"
    UNTRACKED="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
    STAGED_FILES="$STAGED_FILES"$'\n'"$ALL_FILES"$'\n'"$UNTRACKED"
  fi
fi

# De-duplicate and remove empty lines
STAGED_FILES="$(echo "$STAGED_FILES" | sort -u | sed '/^$/d')"

if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Define secret patterns
# ---------------------------------------------------------------------------
VIOLATIONS=""

scan_content() {
  local file="$1"
  local content="$2"
  local file_violations=""

  # Anthropic API keys
  if echo "$content" | grep -qE 'sk-ant-'; then
    file_violations="${file_violations}  - Anthropic API key (sk-ant-) detected"$'\n'
  fi

  # OpenAI keys: sk- followed by 20+ chars (but not sk-ant- which is Anthropic)
  if echo "$content" | grep -qE 'sk-[A-Za-z0-9]{20,}' | grep -vq 'sk-ant-' 2>/dev/null; then
    # More precise check: find sk- matches that are NOT sk-ant-
    if echo "$content" | grep -oE 'sk-[A-Za-z0-9_-]{20,}' | grep -vq '^sk-ant-'; then
      file_violations="${file_violations}  - Possible OpenAI key (sk-...) detected"$'\n'
    fi
  fi

  # AWS access keys
  if echo "$content" | grep -qE 'AKIA[0-9A-Z]{16}'; then
    file_violations="${file_violations}  - AWS access key (AKIA...) detected"$'\n'
  fi

  # GitHub tokens
  if echo "$content" | grep -qE 'gh[ps]_[A-Za-z0-9_]{36,}'; then
    file_violations="${file_violations}  - GitHub token (ghp_/ghs_) detected"$'\n'
  fi

  # Slack tokens
  if echo "$content" | grep -qE 'xoxb-'; then
    file_violations="${file_violations}  - Slack bot token (xoxb-) detected"$'\n'
  fi
  if echo "$content" | grep -qE 'xapp-'; then
    file_violations="${file_violations}  - Slack app token (xapp-) detected"$'\n'
  fi

  # SSH private key PEM headers
  if echo "$content" | grep -qE '-----BEGIN.*PRIVATE KEY-----'; then
    file_violations="${file_violations}  - SSH/TLS private key (PEM header) detected"$'\n'
  fi

  # Long base64 strings (40+ chars) that look like secrets
  if echo "$content" | grep -qE '[A-Za-z0-9+/]{40,}=*'; then
    # Only flag if it looks like it could be a secret (not just code or text)
    if echo "$content" | grep -qE '(key|secret|token|password|credential|auth).*[A-Za-z0-9+/]{40,}=*' || \
       echo "$content" | grep -qE '[A-Za-z0-9+/]{40,}=*.*(key|secret|token|password|credential|auth)'; then
      file_violations="${file_violations}  - Long base64 string near secret-related keyword detected"$'\n'
    fi
  fi

  # Generic patterns: API_KEY=, SECRET=, PASSWORD=, TOKEN= with actual values
  if echo "$content" | grep -qE '(API_KEY|SECRET|PASSWORD|TOKEN)\s*=\s*["\x27]?[A-Za-z0-9+/_.@#$%^&*-]{4,}'; then
    # Exclude placeholder values
    if ! echo "$content" | grep -qE '(API_KEY|SECRET|PASSWORD|TOKEN)\s*=\s*["\x27]?(changeme|placeholder|your[_-]|xxx|TODO|REPLACE|example|test|dummy|sample|none|null|empty)'; then
      file_violations="${file_violations}  - Hardcoded secret assignment (API_KEY/SECRET/PASSWORD/TOKEN=<value>) detected"$'\n'
    fi
  fi

  if [[ -n "$file_violations" ]]; then
    VIOLATIONS="${VIOLATIONS}File: ${file}"$'\n'"${file_violations}"
  fi
}

# ---------------------------------------------------------------------------
# 5. Scan staged files
# ---------------------------------------------------------------------------
while IFS= read -r file; do
  [[ -z "$file" ]] && continue

  # Check for sensitive file types regardless of content
  if echo "$file" | grep -qE '\.pem$'; then
    VIOLATIONS="${VIOLATIONS}File: ${file}"$'\n'"  - PEM file staged for commit (likely contains private key material)"$'\n'
    continue
  fi

  if echo "$file" | grep -qE '\.env($|\.)'; then
    # .env files are almost always secrets
    if [[ -f "$file" ]]; then
      CONTENT="$(cat "$file" 2>/dev/null || true)"
      if [[ -n "$CONTENT" ]]; then
        VIOLATIONS="${VIOLATIONS}File: ${file}"$'\n'"  - Environment file (.env) staged for commit (likely contains secrets)"$'\n'
        scan_content "$file" "$CONTENT"
      fi
    fi
    continue
  fi

  if echo "$file" | grep -qiE '^config/.*key'; then
    VIOLATIONS="${VIOLATIONS}File: ${file}"$'\n'"  - Config key file staged for commit (likely contains key material)"$'\n'
    continue
  fi

  # For commit, scan the staged version; for add, scan the working copy
  if [[ "$IS_COMMIT" == true ]]; then
    CONTENT="$(git show ":${file}" 2>/dev/null || true)"
  else
    CONTENT="$(cat "$file" 2>/dev/null || true)"
  fi

  if [[ -n "$CONTENT" ]]; then
    scan_content "$file" "$CONTENT"
  fi
done <<< "$STAGED_FILES"

# ---------------------------------------------------------------------------
# 6. Report results
# ---------------------------------------------------------------------------
if [[ -n "$VIOLATIONS" ]]; then
  echo "BLOCKED: Potential secrets detected in staged files!"
  echo ""
  echo "The following issues were found:"
  echo "$VIOLATIONS"
  echo ""
  echo "If these are intentional (e.g., test fixtures), consider:"
  echo "  - Adding the file to .gitignore"
  echo "  - Using environment variables instead of hardcoded values"
  echo "  - Using git update-index --assume-unchanged <file>"
  exit 2
fi

exit 0
