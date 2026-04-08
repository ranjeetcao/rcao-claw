#!/bin/bash
set -euo pipefail

# Usage: run-tests [repo-name] [-- test-args...]
# Defaults to workspace.conf REPO

LOGFILE="$HOME/openclaw/logs/gateway.log"

# Extract repo name (first arg before --)
_REPO=""
_TEST_ARGS=()
_FOUND_SEPARATOR=false

for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
        _FOUND_SEPARATOR=true
        continue
    fi
    if $_FOUND_SEPARATOR; then
        _TEST_ARGS+=("$arg")
    elif [[ -z "$_REPO" ]]; then
        _REPO="$arg"
    fi
done

source "$(dirname "${BASH_SOURCE[0]}")/workspace-env.sh" "$_REPO"

# Block shell metacharacters in test arguments
for _arg in "${_TEST_ARGS[@]}"; do
    if [[ "$_arg" =~ [\;\|\&\$\`\\\(\)\{\}\<\>] ]]; then
        echo "ERROR: Invalid characters in test arguments"
        exit 1
    fi
done

cd "$WORKDIR"

echo "[$(date -Iseconds)] TESTS START: $WORKDIR" >> "$LOGFILE"
npm test -- "${_TEST_ARGS[@]}"
EXIT_CODE=$?
echo "[$(date -Iseconds)] TESTS END: exit=$EXIT_CODE" >> "$LOGFILE"
exit $EXIT_CODE
