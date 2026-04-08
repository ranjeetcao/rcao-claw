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

# Wait for Ollama to be ready (healthcheck handles this, but belt-and-suspenders)
echo "[entrypoint] Waiting for Ollama..."
for i in $(seq 1 30); do
    if curl -sf http://ollama:11434/api/tags >/dev/null 2>&1; then
        echo "[entrypoint] Ollama is ready"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "[entrypoint] WARNING: Ollama not responding after 30s, starting anyway"
    fi
    sleep 1
done

# Start Claw gateway (tee to both stdout for docker logs and file for persistence)
echo "[entrypoint] Starting Claw gateway on :3000"
openclaw gateway run \
    --bind 0.0.0.0 \
    --port 3000 \
    --force \
    2>&1 | tee -a /openclaw/logs/openclaw.log
