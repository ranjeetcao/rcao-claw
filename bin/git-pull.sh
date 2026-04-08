#!/bin/bash
set -euo pipefail

# Usage: git-pull [repo-name]   (defaults to workspace.conf REPO)
source "$(dirname "${BASH_SOURCE[0]}")/workspace-env.sh" "${1:-}"

cd "$WORKDIR"
git pull --rebase origin "$(git branch --show-current)"
