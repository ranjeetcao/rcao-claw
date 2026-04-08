#!/bin/bash
set -euo pipefail

# Usage: deploy-staging [repo-name]   (defaults to workspace.conf REPO)
LOGFILE="$HOME/openclaw/logs/gateway.log"

source "$(dirname "${BASH_SOURCE[0]}")/workspace-env.sh" "${1:-}"

cd "$WORKDIR"

echo "[$(date -Iseconds)] DEPLOY STAGING START: $WORKDIR" >> "$LOGFILE"

# TODO: Replace with your actual staging deploy command
echo "ERROR: deploy-staging.sh not configured yet. Edit this script with your deploy command."
exit 1
