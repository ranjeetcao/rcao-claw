#!/bin/bash
# Shared workspace resolver - sourced by all scripts
# Parses .env safely (no shell execution), allows override via argument

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Parse .env safely (grep+cut, NOT source — prevents code injection via .env)
if [[ -f "$ENV_FILE" ]]; then
    _WORKSPACE=$(grep '^WORKSPACE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
    OPENCLAW_VERSION=$(grep '^OPENCLAW_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
else
    _WORKSPACE=""
    OPENCLAW_VERSION=""
fi

# Resolve WORKSPACE path (expand ~ to $HOME)
if [[ -n "$_WORKSPACE" ]]; then
    WORKDIR="${_WORKSPACE/#\~/$HOME}"
else
    WORKDIR="$HOME/workspace"
fi

# Allow override via first argument (full path or repo name under parent dir)
_OVERRIDE="${1:-}"
if [[ -n "$_OVERRIDE" ]]; then
    # Block path traversal
    if [[ "$_OVERRIDE" == *".."* ]]; then
        echo "ERROR: Invalid path: $_OVERRIDE"
        exit 1
    fi
    # Block shell metacharacters
    if [[ "$_OVERRIDE" =~ [\;\|\&\$\`\\\(\)\{\}\<\>] ]]; then
        echo "ERROR: Invalid characters in path: $_OVERRIDE"
        exit 1
    fi
    # If it's a relative name, resolve under the parent of WORKDIR
    if [[ "$_OVERRIDE" != /* ]]; then
        WORKSPACE_PARENT="$(dirname "$WORKDIR")"
        WORKDIR="$WORKSPACE_PARENT/$_OVERRIDE"
    else
        WORKDIR="$_OVERRIDE"
    fi
fi

# Verify directory exists
if [[ ! -d "$WORKDIR" ]]; then
    echo "ERROR: Directory not found: $WORKDIR"
    WORKSPACE_PARENT="$(dirname "$WORKDIR")"
    if [[ -d "$WORKSPACE_PARENT" ]]; then
        echo "Available repos under $WORKSPACE_PARENT:"
        ls -1 "$WORKSPACE_PARENT" 2>/dev/null || echo "  (none)"
    fi
    echo ""
    echo "Set WORKSPACE in: $ENV_FILE"
    exit 1
fi

export WORKDIR
export OPENCLAW_VERSION
