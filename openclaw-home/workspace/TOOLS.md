# Tools

## Available Host Commands
See AGENTS.md for the full commands reference table.

## Claude Code Capabilities (inside run-claude)

**Allowed:**
- Read, Edit, Write, Glob, Grep
- npm test, npm run, npm install, npm ci
- git diff/log/status/show/add/commit/branch/checkout/stash/remote
- node src/*, node scripts/* (run specific files)
- ls, mkdir, rm (single files by extension), head, tail, wc, sort, which

**Blocked:**
- node -e, npx (arbitrary code execution)
- curl, wget, ssh, sudo, docker (network/system access)
- python, python3, ruby, perl, awk, sed (interpreter escape)
- rm -rf, rm -r (bulk deletion)
- bash -c, sh -c, eval, exec (shell escape)
- git push, git rebase, git reset, git merge, git config (destructive git ops)
- pip, pip3, find, xargs, tee, ln (sandbox escape vectors)
- WebFetch, WebSearch (internet access)

**Limits:** 25 turns max, $10 budget per run

## Workflow Examples

### Typical task flow
```
1. git-status f2p-root                    # check current state
2. git-pull f2p-root                      # get latest
3. run-claude "read the auth module and create a plan for adding refresh token rotation" f2p-root
4. [review the plan with agents]
5. [address review comments]
6. run-claude "implement refresh token rotation following the approved plan. create feature branch, write tests, use conventional commits" f2p-root
7. run-tests f2p-root                     # verify
8. [launch review agents]
9. [fix review comments]
10. [create PR]
```

### Prompting tips for run-claude
- Start with context: "In user-service/src/auth/..."
- Reference existing patterns: "following the same pattern as..."
- Be explicit about branch: "create a feature branch named feat/refresh-tokens"
- Ask for tests: "include unit tests following existing test patterns"
- Ask for conventional commits: "commit with conventional commit format"

## Slack

Slack is connected via OpenClaw's **native plugin** using Socket Mode (WebSocket). You can send messages, read channels, and react — all through the gateway. No SSH commands needed.

### How it works
- OpenClaw connects to Slack via Socket Mode (real-time WebSocket)
- All Slack traffic is proxied through Squid (`HTTPS_PROXY=http://squid:3128`)
- Only `*.slack.com` and `*.slack-edge.com` domains are allowed (Squid ACL)
- HTTPS only (port 443)
- Audit trail: `logs/squid/access.log` for all proxy requests

### Capabilities
- Send messages to channels
- Read channel history and threads
- React to messages
- Receive real-time events (mentions, DMs, channel messages)

### Security
- Only `*.slack.com` + `*.slack-edge.com` allowed (Squid ACL)
- HTTPS only (port 443)
- Ollama stays fully air-gapped (does not use the proxy)
- All proxy requests logged to `logs/squid/access.log`
