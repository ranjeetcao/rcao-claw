# Slack Integration

Claw connects to Slack using its **native Slack plugin** with Socket Mode (real-time WebSocket). All traffic is routed through a Squid forward proxy that whitelists only `*.slack.com` and `*.slack-edge.com` domains.

## Architecture

```
zupee-claw container (joins squid-net + isolated + host-access)
  |
  | HTTPS_PROXY=http://squid:3128
  v
zupee-squid (Docker, squid-net)
  Squid proxy — ACL: ONLY *.slack.com, port 443
  |
  v (internet)
Slack API (REST + Socket Mode WebSocket)
```

**Key points:**
- Claw's native Slack plugin handles all communication (real-time via Socket Mode)
- The `zupee-claw` container joins `squid-net` and uses `HTTPS_PROXY` to reach Squid
- Squid ACL is the security boundary — only `*.slack.com` + `*.slack-edge.com` allowed
- `NO_PROXY=ollama` ensures Ollama traffic stays on the isolated network
- The `zupee-ollama` container does NOT join `squid-net` — fully air-gapped

## Setup

### 1. Create a Slack App (Socket Mode)

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and create a new app
2. Enable **Socket Mode** under Settings > Socket Mode
3. Generate an **App-Level Token** with `connections:write` scope (starts with `xapp-`)
4. Under **OAuth & Permissions**, add these bot token scopes (minimal):
   - `chat:write` — send messages
   - `channels:history` — read public channel history
   - `channels:read` — list channels
5. Under **Event Subscriptions**, enable events and subscribe to:
   - `message.channels` — messages in public channels
   - `app_mention` — when the bot is @mentioned
6. Install the app to your workspace
7. Copy the **Bot User OAuth Token** (starts with `xoxb-`)

**Do NOT add:** `files:write`, `users:read`, `admin.*`, or any other scopes.

### 2. Configure Environment

Add to your `.env`:

```bash
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_APP_TOKEN=xapp-your-app-token
```

| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_BOT_TOKEN` | Yes | Bot token (starts with `xoxb-`) |
| `SLACK_APP_TOKEN` | Yes | App-level token for Socket Mode (starts with `xapp-`) |

### 3. Enable in openclaw.json

Already configured in the default `openclaw.json`:

```json
{
  "channels": {
    "slack": {
      "enabled": true,
      "mode": "socket"
    }
  }
}
```

### 4. Start Services

```bash
make up
```

Squid and Claw start together. Claw waits for Squid to be healthy before starting.

## Verification

```bash
# Squid allows Slack
curl --proxy http://127.0.0.1:3128 https://slack.com/api/api.test

# Squid blocks everything else
curl --proxy http://127.0.0.1:3128 https://google.com
# Should return 403

# Check Squid health
make health

# Check proxy logs for Slack traffic
tail -f logs/squid/access.log
```

Once running, Slack events should appear in the Claw Web UI in real-time. Send a test message by @mentioning the bot in a channel.

## Security Model

| Layer | Protection |
|-------|-----------|
| Squid ACL | Only `*.slack.com` + `*.slack-edge.com` allowed |
| Squid port restriction | Only HTTPS (port 443) |
| `NO_PROXY` | Ollama traffic stays on isolated network |
| Docker network isolation | Ollama does NOT join `squid-net` |
| Proxy-only internet | Container has no direct internet — only through Squid |
| Slack bot scopes | Minimal: `chat:write`, `channels:history`, `channels:read` |
| Slack app-level scope | `connections:write` (required for Socket Mode) |
| Audit trail | `logs/squid/access.log` for all proxy requests |

### What Claw CANNOT Do

- Access any website other than `*.slack.com`
- Use HTTP (only HTTPS port 443)
- Bypass the proxy (all outbound traffic goes through `HTTPS_PROXY`)
- Access the internet from Ollama (Ollama stays fully air-gapped)

## Troubleshooting

### Slack not connecting

1. Check both tokens are set in `.env`:
   ```bash
   grep SLACK .env
   ```
2. Verify Socket Mode is enabled in your Slack app settings
3. Check Claw logs for connection errors:
   ```bash
   make logs
   ```

### "curl: (56) Received HTTP code 403 from proxy"

The domain is blocked by Squid ACLs. Only `*.slack.com` and `*.slack-edge.com` are allowed.

### Squid proxy not responding

```bash
# Check if Squid container is running
docker ps | grep zupee-squid

# Check Squid logs
tail -f logs/squid/access.log

# Restart Squid
cd docker && docker compose restart squid
```

### "not_in_channel" error from Slack

Invite the bot to the channel: `/invite @YourBotName` in Slack.

### Ollama requests failing

Check that `NO_PROXY=ollama` is set in `docker-compose.yml`. Ollama traffic should not go through the proxy.
