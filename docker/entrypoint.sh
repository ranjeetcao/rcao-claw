#!/bin/bash
set -euo pipefail

echo "[entrypoint] Starting Claw container..."

# Setup SSH key (copy to writable location with correct permissions)
mkdir -p /home/openclaw/.ssh
if [[ -f /openclaw/.ssh/id_ed25519 ]]; then
    cp /openclaw/.ssh/id_ed25519 /home/openclaw/.ssh/id_ed25519
    chmod 600 /home/openclaw/.ssh/id_ed25519
    echo "[entrypoint] SSH key configured"
fi

# Add host to known_hosts (only if not already present)
if ! grep -q "host.docker.internal" /home/openclaw/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -H host.docker.internal >> /home/openclaw/.ssh/known_hosts 2>/dev/null || true
fi

# Verify openclaw-home is mounted
if [[ ! -f /home/openclaw/.openclaw/openclaw.json ]]; then
    echo "[entrypoint] WARNING: ~/.openclaw/openclaw.json not found. Is openclaw-home mounted?"
fi

# Harden personality files — the agent must not be able to rewrite its own identity/rules.
# These files are owned by the host user (UID 1000), not the container user (UID 1001),
# so the agent already cannot modify them. The chmod below is defense-in-depth for cases
# where host permissions are misconfigured.
for f in AGENTS.md SOUL.md USER.md IDENTITY.md TOOLS.md; do
    chmod 444 "/home/openclaw/.openclaw/workspace/$f" 2>/dev/null || true
done
echo "[entrypoint] Personality files verified"

# Allow git operations on mounted workspace (owner differs from container user)
if command -v git &>/dev/null && [[ -d /workspace ]]; then
    git config --global --add safe.directory /workspace 2>/dev/null || true
    echo "[entrypoint] Git safe.directory configured for /workspace"
fi

# Wait for Ollama to be ready (may be Docker container or native host install)
OLLAMA_API="${OLLAMA_HOST:-http://ollama:11434}"
echo "[entrypoint] Waiting for Ollama at $OLLAMA_API..."
for i in $(seq 1 30); do
    if curl -sf "${OLLAMA_API}/api/tags" >/dev/null 2>&1; then
        echo "[entrypoint] Ollama is ready"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "[entrypoint] WARNING: Ollama not responding after 30s, starting anyway"
    fi
    sleep 1
done

# Start Claw gateway (tee to both stdout for docker logs and file for persistence)
# --bind custom: bind to 0.0.0.0 inside the container (safe — host port mapping is
#   restricted to 127.0.0.1 in docker-compose.yml). Using "custom" instead of "lan"
#   avoids ambiguity when the container has multiple Docker networks.
# --force is intentionally omitted: it requires fuser/lsof (not in this image), and
#   is unnecessary — Docker guarantees a clean process namespace on container start.
echo "[entrypoint] Starting Claw gateway on :3000"
openclaw gateway run \
    --bind custom \
    --port 3000 \
    2>&1 | tee -a /openclaw/logs/openclaw.log
