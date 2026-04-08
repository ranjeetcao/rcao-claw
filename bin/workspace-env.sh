#!/bin/bash
# Shared workspace resolver - sourced by all scripts
# Parses .env safely (no shell execution), allows override via argument

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$HOME/workspace"
ENV_FILE="$SCRIPT_DIR/../.env"

# Parse .env safely (grep+cut, NOT source — prevents code injection via .env)
if [[ -f "$ENV_FILE" ]]; then
    REPO=$(grep '^REPO=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
    OPENCLAW_VERSION=$(grep '^OPENCLAW_VERSION=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
else
    REPO=""
    OPENCLAW_VERSION=""
fi

# Allow override via first argument (if caller passes one)
_REPO_OVERRIDE="${1:-}"
if [[ -n "$_REPO_OVERRIDE" ]]; then
    REPO="$_REPO_OVERRIDE"
fi

# Resolve full path
if [[ -n "$REPO" ]]; then
    # Block path traversal
    if [[ "$REPO" == *".."* ]] || [[ "$REPO" == /* ]]; then
        echo "ERROR: Invalid repo name: $REPO"
        exit 1
    fi
    # Block shell metacharacters in repo name
    if [[ "$REPO" =~ [\;\|\&\$\`\\\(\)\{\}\<\>] ]]; then
        echo "ERROR: Invalid characters in repo name: $REPO"
        exit 1
    fi
    WORKDIR="$WORKSPACE_ROOT/$REPO"
else
    WORKDIR="$WORKSPACE_ROOT"
fi

# Verify directory exists
if [[ ! -d "$WORKDIR" ]]; then
    echo "ERROR: Directory not found: $WORKDIR"
    echo "Available repos under $WORKSPACE_ROOT:"
    ls -1 "$WORKSPACE_ROOT" 2>/dev/null || echo "  (none)"
    echo ""
    echo "Set default repo in: $ENV_FILE"
    exit 1
fi

export WORKDIR
export REPO
export OPENCLAW_VERSION
