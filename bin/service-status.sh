#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared env parser (no duplication)
source "$SCRIPT_DIR/workspace-env.sh" ""

WORKSPACE_PARENT="$(dirname "$WORKDIR")"

echo "=== Configuration ==="
echo "OPENCLAW_VERSION=$OPENCLAW_VERSION"
echo ""
echo "=== Default Workspace ==="
echo "WORKSPACE=$WORKDIR"
echo ""
echo "=== Available Repos ==="
ls -1 "$WORKSPACE_PARENT" 2>/dev/null || echo "  (none)"
echo ""
echo "=== Disk Usage ==="
df -h "$WORKSPACE_PARENT" 2>/dev/null || echo "workspace not found"
