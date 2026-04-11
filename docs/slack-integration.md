# Slack Integration

Each developer's Claw communicates AS the developer using their own Slack user token. Messages appear from the developer, not from a bot — the team sees natural human communication, powered by the AI agent.

## Architecture

```
Developer A's laptop                    Developer B's laptop
  Claw A                                  Claw B
    │ (xoxp-A user token)                   │ (xoxp-B user token)
    │                                       │
    ├─→ Sends as Dev A                      ├─→ Sends as Dev B
    ├─→ Reads #dev-backend channel          ├─→ Reads #dev-backend channel
    ├─→ Reads Dev A's DMs                   ├─→ Reads Dev B's DMs
    │                                       │
    v                                       v
  Squid Proxy (HTTPS only, *.slack.com)   Squid Proxy
    │                                       │
    v                                       v
  Slack API (Socket Mode WebSocket)       Slack API
```

**Key points:**
- One Slack app, created once by admin
- Each developer authorizes → gets their own `xoxp-` user token
- No bot identity — Claw speaks as the developer
- Claw listens to channels and DMs, responds when relevant (no @mention needed)
- All Slack traffic proxied through Squid (HTTPS only, `*.slack.com`)

## Setup

### 1. Create a Slack App (one-time, admin)

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → Create New App
2. Enable **Socket Mode** under Settings → Socket Mode
3. Generate an **App-Level Token** with `connections:write` scope → copy `xapp-...`
4. Under **OAuth & Permissions**, add **User Token Scopes** (NOT bot scopes):

   | Scope | Purpose |
   |-------|---------|
   | `chat:write` | Send messages as the developer |
   | `channels:history` | Read public channel messages |
   | `channels:read` | List channels |
   | `groups:history` | Read private channel messages |
   | `groups:read` | List private channels |
   | `im:history` | Read DM messages |
   | `im:read` | List DM conversations |
   | `im:write` | Open DM conversations |
   | `users:read` | Look up user info |
   | `reactions:read` | Read reactions |
   | `reactions:write` | Add reactions |
   | `pins:read` | Read pinned messages |
   | `files:read` | Access shared files |

5. Under **Event Subscriptions**, enable and subscribe to:
   - `message.channels` — public channel messages
   - `message.groups` — private channel messages
   - `message.im` — DM messages
   - `message.mpim` — group DM messages
   - `reaction_added`, `reaction_removed`

6. Share the **App-Level Token** (`xapp-...`) with all developers (same for everyone)

### 2. Each Developer Installs the App

Each developer:

1. Visits the app's install URL (admin provides this)
2. Authorizes with their own Slack account
3. Copies their **User OAuth Token** (`xoxp-...`)
4. Adds to their `.env`:

```bash
SLACK_APP_TOKEN=xapp-shared-app-token        # Same for all developers
SLACK_USER_TOKEN=xoxp-your-personal-token    # Unique per developer
```

### 3. Run Setup

```bash
./setup.sh --role developer
```

Setup automatically configures OpenClaw with:
- Socket Mode using the app token
- User token for read + write (messages appear as you)
- Open channel policy (responds without @mention when relevant)
- DM support enabled

### 4. Verify

```bash
# Check Slack connection
docker logs zupee-claw 2>&1 | grep -i slack

# Send a test from the Web UI and check if it appears in Slack
```

## How It Works

### Channels

Claw monitors all public channels the developer is in. The reasoning model decides when to engage:

- **Responds when relevant** — if Claw has context about the topic (reviewed that code, knows the architecture)
- **Stays silent** — for casual chat, HR discussions, etc.
- **No @mention needed** — Claw reads the conversation and decides

Example:
```
#dev-backend:
  Dev A: "the auth refresh is failing on staging"
  Dev B: "which service?"
  Dev A: "user-service, getting 401 after token expires"
  
  [Dev A's Claw has context — it reviewed user-service auth yesterday]
  Dev A (via Claw): "The refresh grace period is 30s in user-service.
    Staging might have clock skew causing the 401. Check with:
    docker exec user-service date vs host date"
```

### DMs

Claw can read and respond to DMs. When someone DMs the developer:

- Claw sees the message
- If it can help (code question, review request), it responds as the developer
- The other person doesn't know it's the AI — it appears as a normal reply

### Proposals

When Claw creates a proposal PR, it notifies the team:

```
#dev-backend:
  Dev A (via Claw): "Created proposal: api-gateway-hardening
    Found 3 issues: dead code, query param corruption, JWT cache thrashing
    PR: github.com/team/repo/pull/234"
```

## Security

| Layer | Protection |
|-------|-----------|
| Squid ACL | Only `*.slack.com` + `*.slack-edge.com` allowed |
| HTTPS only | Port 443, no HTTP |
| User token scope | Minimal scopes — no admin, no workspace management |
| Docker isolation | Slack traffic flows through proxy, not direct internet |
| Audit trail | `logs/squid/access.log` for all proxy requests |

### What Claw CANNOT Do via Slack
- Manage workspace settings (no admin scopes)
- Install apps or integrations
- Access channels the developer isn't in
- Delete other people's messages
- Access Slack Connect external channels (unless developer has access)

## Troubleshooting

### Slack not connecting
```bash
# Check tokens are set
grep SLACK .env

# Check container logs for Slack errors
docker logs zupee-claw 2>&1 | grep -i "slack\|socket"

# Check Squid allows Slack traffic
curl --proxy http://127.0.0.1:3128 https://slack.com/api/api.test
```

### Messages not appearing as the developer
- Verify you're using `SLACK_USER_TOKEN` (xoxp-...), NOT `SLACK_BOT_TOKEN` (xoxb-...)
- Check `userTokenReadOnly` is `false` in OpenClaw config
- Verify no `botToken` is configured (bot token takes priority for writes)

### Claw responding to everything
- Adjust the reasoning model or personality files
- Add channel-specific config to limit which channels Claw monitors
- Set `requireMention: true` on noisy channels
