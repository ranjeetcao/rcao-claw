#!/bin/bash
set -euo pipefail

# Usage: git-status [repo-name]   (defaults to workspace.conf REPO)
source "$(dirname "${BASH_SOURCE[0]}")/workspace-env.sh" "${1:-}"

cd "$WORKDIR"
git status
