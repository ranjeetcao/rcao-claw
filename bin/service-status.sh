#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared env parser (no duplication)
source "$SCRIPT_DIR/workspace-env.sh" ""

echo "=== Configuration ==="
echo "OPENCLAW_VERSION=$OPENCLAW_VERSION"
echo ""
echo "=== Default Workspace ==="
if [[ -n "$REPO" ]]; then
    echo "REPO=$REPO  ->  $WORKDIR"
else
    echo "REPO=(not set)  ->  $WORKDIR"
fi
echo ""
echo "=== Available Repos ==="
WORKSPACE_ROOT="$HOME/workspace"
ls -1 "$WORKSPACE_ROOT" 2>/dev/null || echo "  (none)"
echo ""
echo "=== Disk Usage ==="
df -h "$WORKSPACE_ROOT" 2>/dev/null || echo "workspace not found"
