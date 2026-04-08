#!/bin/bash
set -euo pipefail

# Launch Claude Code with locked-down permissions
# Usage: run-claude <prompt> [repo-name]
# Defaults to .env REPO
#
# Permissions co-source-of-truth: config/claude-settings.json
# Keep --allowedTools / --disallowedTools in sync with that file.

LOGFILE="$HOME/openclaw/logs/claude.log"

if [[ $# -lt 1 ]]; then
    echo "Usage: run-claude <prompt> [repo-name]"
    exit 1
fi

PROMPT="$1"

source "$(dirname "${BASH_SOURCE[0]}")/workspace-env.sh" "${2:-}"

# Reject excessively long prompts
if [[ ${#PROMPT} -gt 8000 ]]; then
    echo "[$(date -Iseconds)] DENIED: prompt too long (${#PROMPT} chars)" >> "$LOGFILE"
    echo "ERROR: Prompt exceeds 8000 character limit (actual: ${#PROMPT} chars). Break into smaller prompts."
    exit 1
fi

echo "[$(date -Iseconds)] CLAUDE START: dir=$WORKDIR prompt=${PROMPT:0:100}..." >> "$LOGFILE"

cd "$WORKDIR"

claude -p "$PROMPT" \
  --permission-mode dontAsk \
  --allowedTools '"Read" "Edit" "Write" "Glob" "Grep" "Bash(npm test *)" "Bash(npm run *)" "Bash(npm install *)" "Bash(npm ci)" "Bash(git diff *)" "Bash(git log *)" "Bash(git status)" "Bash(git show *)" "Bash(git add *)" "Bash(git commit *)" "Bash(git branch *)" "Bash(git checkout *)" "Bash(git stash *)" "Bash(git remote *)" "Bash(node src/*)" "Bash(node scripts/*)" "Bash(node dist/*)" "Bash(ls *)" "Bash(mkdir *)" "Bash(rm *.ts)" "Bash(rm *.js)" "Bash(rm *.json)" "Bash(rm *.md)" "Bash(rm *.css)" "Bash(rm *.html)" "Bash(wc *)" "Bash(head *)" "Bash(tail *)" "Bash(sort *)" "Bash(which *)"' \
  --disallowedTools '"Bash(node -e *)" "Bash(node --eval *)" "Bash(node -p *)" "Bash(node --print *)" "Bash(npx *)" "Bash(curl *)" "Bash(wget *)" "Bash(rm -rf *)" "Bash(rm -r *)" "Bash(ssh *)" "Bash(sudo *)" "Bash(su *)" "Bash(chmod *)" "Bash(chown *)" "Bash(kill *)" "Bash(pkill *)" "Bash(dd *)" "Bash(nc *)" "Bash(ncat *)" "Bash(python *)" "Bash(python3 *)" "Bash(ruby *)" "Bash(perl *)" "Bash(awk *)" "Bash(sed *)" "Bash(tee *)" "Bash(xargs *)" "Bash(find *)" "Bash(pip *)" "Bash(pip3 *)" "Bash(ln *)" "Bash(eval *)" "Bash(exec *)" "Bash(nohup *)" "Bash(crontab *)" "Bash(docker *)" "Bash(mount *)" "Bash(umount *)" "Bash(open *)" "Bash(xdg-open *)" "Bash(pbcopy *)" "Bash(osascript *)" "Bash(env *)" "Bash(export *)" "Bash(source *)" "Bash(bash -c *)" "Bash(sh -c *)" "Bash(git push *)" "Bash(git rebase *)" "Bash(git reset *)" "Bash(git merge *)" "Bash(git config *)" "WebFetch" "WebSearch"' \
  --max-turns 25 \
  --max-budget-usd 10.00 \
  2>&1 | tee -a "$LOGFILE"

EXIT_CODE=${PIPESTATUS[0]}
echo "[$(date -Iseconds)] CLAUDE END: exit=$EXIT_CODE" >> "$LOGFILE"
exit $EXIT_CODE
