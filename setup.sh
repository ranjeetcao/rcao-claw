#!/bin/bash
set -euo pipefail

# =============================================================================
# Zupee Claw - End-to-End Setup
# Provisions everything needed to run Claw in Docker with SSH gateway
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }
step()  { echo -e "\n${GREEN}=== $* ===${NC}"; }

# --- Auto-create .env if missing ---------------------------------------------

ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
        cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
        info "Created .env from .env.example (edit to customize)"
    else
        error ".env.example not found. Cannot continue."
        exit 1
    fi
fi

# Parse .env safely (no source — prevents code injection)
# || true: grep exits 1 if key is missing — don't abort under set -euo pipefail
OPENCLAW_VERSION=$(grep '^OPENCLAW_VERSION=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
REPO=$(grep '^REPO=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
_WORKSPACE_DIR=$(grep '^WORKSPACE_DIR=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
OLLAMA_MODEL=$(grep '^OLLAMA_MODEL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
OLLAMA_MODEL_MEM=$(grep '^OLLAMA_MODEL_MEM=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
OLLAMA_MODE=$(grep '^OLLAMA_MODE=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
OLLAMA_MODE="${OLLAMA_MODE:-auto}"

# Resolve "auto" mode: native on macOS (Metal GPU), docker on Linux
if [[ "$OLLAMA_MODE" == "auto" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        OLLAMA_MODE="native"
    else
        OLLAMA_MODE="docker"
    fi
fi

# Resolve WORKSPACE_DIR (expand ~ to $HOME), fallback to $HOME/workspace
if [[ -n "${_WORKSPACE_DIR:-}" ]]; then
    WORKSPACE_BASE="${_WORKSPACE_DIR/#\~/$HOME}"
else
    WORKSPACE_BASE="$HOME/workspace"
fi

# Fallback for OLLAMA_MODEL
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.5}"
# Fallback for model memory (GiB) — 3 GiB is safe for small models
OLLAMA_MODEL_MEM="${OLLAMA_MODEL_MEM:-3}"

# --- Pre-flight checks -------------------------------------------------------

step "Pre-flight checks"

info "Ollama mode: $OLLAMA_MODE"

if ! command -v docker &>/dev/null; then
    error "Docker not found. Install Docker first."
    exit 1
fi
info "Docker found: $(docker --version)"

if ! docker compose version &>/dev/null; then
    error "Docker Compose not found."
    exit 1
fi
info "Docker Compose found: $(docker compose version --short)"

if ! command -v ssh-keygen &>/dev/null; then
    error "ssh-keygen not found."
    exit 1
fi
info "SSH tools available"

if ! command -v jq &>/dev/null; then
    error "jq not found. Install jq first (e.g., apt install jq / brew install jq)."
    exit 1
fi
info "jq available"

if [[ "$OLLAMA_MODE" == "native" ]]; then
    if ! command -v ollama &>/dev/null; then
        error "Ollama not found. Install from https://ollama.com/download"
        exit 1
    fi
    info "Ollama found: $(ollama --version 2>&1 | head -1)"
fi

# Detect system resources
TOTAL_CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
TOTAL_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || \
    sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1048576)}' || echo 8192)

if [[ "$TOTAL_CPUS" -lt 4 ]]; then
    warn "Only ${TOTAL_CPUS} CPUs detected. Recommended: 4+ for comfortable usage."
fi

# Service baseline memory overhead (MiB)
CLAW_BASELINE_MB=512        # Claw gateway (~0.5 GiB)
SQUID_BASELINE_MB=256       # Squid proxy (~0.25 GiB)

export CLAW_MEM="${CLAW_BASELINE_MB}M"
export CLAW_CPUS=$(awk "BEGIN {v=$TOTAL_CPUS * 0.25; if (v < 0.25) v = 0.25; printf \"%.1f\", v}")

# Set OLLAMA_HOST based on mode
if [[ "$OLLAMA_MODE" == "native" ]]; then
    export OLLAMA_HOST="http://host.docker.internal:11434"
else
    export OLLAMA_HOST="http://ollama:11434"
fi

info "System: ${TOTAL_CPUS} CPUs, ${TOTAL_MEM_MB}MB RAM"
info "Model:  $OLLAMA_MODEL (${OLLAMA_MODEL_MEM} GiB)"

if [[ "$OLLAMA_MODE" == "native" ]]; then
    info "Ollama: native mode (Metal GPU, full system resources)"
    info "  Claw limits: ${CLAW_CPUS} CPUs, ${CLAW_MEM}"
else
    OLLAMA_OVERHEAD_MB=512
    OLLAMA_MODEL_MEM_MB=$(( OLLAMA_MODEL_MEM * 1024 ))
    export OLLAMA_MEM="$(( OLLAMA_MODEL_MEM_MB + OLLAMA_OVERHEAD_MB ))M"
    export OLLAMA_CPUS=$(awk "BEGIN {v=$TOTAL_CPUS * 0.50; if (v < 0.5) v = 0.5; printf \"%.1f\", v}")

    TOTAL_NEEDED_MB=$(( OLLAMA_MODEL_MEM_MB + OLLAMA_OVERHEAD_MB + CLAW_BASELINE_MB + SQUID_BASELINE_MB ))
    TOTAL_NEEDED_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_NEEDED_MB / 1024}")

    info "  Ollama limits: ${OLLAMA_CPUS} CPUs, ${OLLAMA_MEM} (model ${OLLAMA_MODEL_MEM}G + overhead)"
    info "  Claw limits:   ${CLAW_CPUS} CPUs, ${CLAW_MEM}"
    info "  Total needed:  ${TOTAL_NEEDED_GB} GiB Docker memory"

    # Preflight check: does Docker have enough memory?
    DOCKER_MEM_MB=""
    if [[ "$(uname)" == "Darwin" ]]; then
        DOCKER_MEM_MB=$(docker info --format '{{.MemTotal}}' 2>/dev/null \
            | awk '{print int($1/1048576)}' || true)
    fi
    DOCKER_MEM_MB="${DOCKER_MEM_MB:-$TOTAL_MEM_MB}"

    if [[ "$DOCKER_MEM_MB" -gt 0 ]] && [[ "$TOTAL_NEEDED_MB" -gt "$DOCKER_MEM_MB" ]]; then
        DOCKER_MEM_GB=$(awk "BEGIN {printf \"%.1f\", $DOCKER_MEM_MB / 1024}")
        error "Docker has ${DOCKER_MEM_GB} GiB memory, but $OLLAMA_MODEL needs ${TOTAL_NEEDED_GB} GiB total."
        echo ""
        echo "  Options:"
        echo "    1. Increase Docker Desktop memory to at least ${TOTAL_NEEDED_GB} GiB"
        echo "       (Docker Desktop > Settings > Resources > Memory)"
        echo "    2. Use a smaller model (edit OLLAMA_MODEL and OLLAMA_MODEL_MEM in .env)"
        echo "    3. Switch to native mode: set OLLAMA_MODE=native in .env"
        echo ""
        exit 1
    elif [[ "$DOCKER_MEM_MB" -gt 0 ]]; then
        DOCKER_MEM_GB=$(awk "BEGIN {printf \"%.1f\", $DOCKER_MEM_MB / 1024}")
        HEADROOM_MB=$(( DOCKER_MEM_MB - TOTAL_NEEDED_MB ))
        if [[ "$HEADROOM_MB" -lt 1024 ]]; then
            warn "Docker has ${DOCKER_MEM_GB} GiB, need ${TOTAL_NEEDED_GB} GiB — tight."
        else
            info "Docker memory: ${DOCKER_MEM_GB} GiB available (${TOTAL_NEEDED_GB} GiB needed) — OK"
        fi
    fi
fi

# Persist calculated resource limits to .env so that standalone
# 'docker compose up' picks them up (compose reads .env automatically).
# Always persist OLLAMA_HOST and mode; only persist resource limits in docker mode
PERSIST_VARS="CLAW_MEM CLAW_CPUS OLLAMA_HOST OLLAMA_MODE"
if [[ "$OLLAMA_MODE" == "docker" ]]; then
    PERSIST_VARS="$PERSIST_VARS OLLAMA_MEM OLLAMA_CPUS"
fi
for VAR_NAME in $PERSIST_VARS; do
    VAR_VAL="${!VAR_NAME}"
    if grep -q "^${VAR_NAME}=" "$ENV_FILE" 2>/dev/null; then
        # Update existing value
        sed -i.bak "s|^${VAR_NAME}=.*|${VAR_NAME}=${VAR_VAL}|" "$ENV_FILE"
    else
        # Append new value
        echo "${VAR_NAME}=${VAR_VAL}" >> "$ENV_FILE"
    fi
done
rm -f "${ENV_FILE}.bak"
info "Resource limits written to .env"

# --- Create host directories -------------------------------------------------

step "Creating directories"

# Reclaim any files left by a previous container run (owned by UID 1001) FIRST.
# This must happen before mkdir/touch — on re-runs, container-owned files block those operations.
CONTAINER_UID=1001
CONTAINER_GID=1001

if [[ -d "$SCRIPT_DIR/openclaw-home" ]] || [[ -d "$SCRIPT_DIR/logs" ]]; then
    FOREIGN_FILES=$(find "$SCRIPT_DIR/openclaw-home" "$SCRIPT_DIR/logs" -not -user "$(id -u)" 2>/dev/null | head -1)
    if [[ -n "$FOREIGN_FILES" ]]; then
        warn "Found files from a previous container run. Reclaiming ownership (requires sudo)..."
        if sudo chown -R "$(id -u):$(id -g)" "$SCRIPT_DIR/openclaw-home" "$SCRIPT_DIR/logs"; then
            info "Ownership reclaimed"
        else
            error "Failed to reclaim file ownership. Run manually:"
            echo "  sudo chown -R \$(id -u):\$(id -g) $SCRIPT_DIR/openclaw-home $SCRIPT_DIR/logs"
            exit 1
        fi
    fi
fi

mkdir -p "$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR/logs/squid"
mkdir -p "$SCRIPT_DIR/openclaw-home/agents/main/sessions"
mkdir -p "$SCRIPT_DIR/openclaw-home/credentials"
mkdir -p "$SCRIPT_DIR/openclaw-home/skills"
mkdir -p "$SCRIPT_DIR/openclaw-home/workspace/memory"
mkdir -p "$SCRIPT_DIR/openclaw-home/workspace/skills"

# Create MEMORY.md if missing (docker bind-mounts it as a file)
touch "$SCRIPT_DIR/openclaw-home/workspace/MEMORY.md"

# Create gateway runtime directories (written to on first start)
for d in canvas devices identity sandboxes tasks; do
    mkdir -p "$SCRIPT_DIR/openclaw-home/$d"
done

# Squid runs as proxy user (UID 13) — needs write access to mounted log dir
chmod 777 "$SCRIPT_DIR/logs/squid"
chmod 777 "$SCRIPT_DIR/logs"

# Parent directory must be traversable by the container user.
# Without this, the container cannot reach any subdirectory even if they are properly owned.
chmod 755 "$SCRIPT_DIR/openclaw-home"

# Gateway config — writable (gateway writes auth token and auto-migrates on first start)
sudo chown "$CONTAINER_UID:$CONTAINER_GID" "$SCRIPT_DIR/openclaw-home/openclaw.json" 2>/dev/null || true

# Gateway runtime dirs — writable
for d in agents canvas devices identity sandboxes skills tasks; do
    sudo chown -R "$CONTAINER_UID:$CONTAINER_GID" "$SCRIPT_DIR/openclaw-home/$d" 2>/dev/null || true
done

# Workspace writable dirs (memory, skills, MEMORY.md)
sudo chown -R "$CONTAINER_UID:$CONTAINER_GID" "$SCRIPT_DIR/openclaw-home/workspace/memory" 2>/dev/null || true
sudo chown -R "$CONTAINER_UID:$CONTAINER_GID" "$SCRIPT_DIR/openclaw-home/workspace/skills" 2>/dev/null || true
sudo chown "$CONTAINER_UID:$CONTAINER_GID" "$SCRIPT_DIR/openclaw-home/workspace/MEMORY.md" 2>/dev/null || true

# chmod fallback — on macOS with Docker Desktop, chown to UID 1001 is unreliable because
# that UID doesn't exist as a real macOS user. VirtioFS file-sharing may show the correct
# owner inside the container but still deny writes based on host-side permission checks.
# Setting explicit chmod ensures the container can read/write regardless of UID mapping.

# macOS: strip com.apple.provenance extended attributes that block chmod/chown.
# Docker Desktop sets these on bind-mounted files; they prevent permission changes
# even after chown reclaims ownership. Requires sudo to remove.
if [[ "$(uname)" == "Darwin" ]]; then
    sudo xattr -rc "$SCRIPT_DIR/openclaw-home" 2>/dev/null || true
    sudo xattr -rc "$SCRIPT_DIR/logs" 2>/dev/null || true
fi

# Writable files: gateway config (auth token written on first start)
sudo chmod 666 "$SCRIPT_DIR/openclaw-home/openclaw.json"
# Writable backup/state files (may or may not exist yet)
for f in "$SCRIPT_DIR/openclaw-home/openclaw.json.bak" "$SCRIPT_DIR/openclaw-home/update-check.json"; do
    [[ -f "$f" ]] && sudo chmod 666 "$f"
done
# Writable directories: gateway runtime + agent memory/skills
for d in agents canvas devices identity sandboxes skills tasks; do
    sudo chmod -R 777 "$SCRIPT_DIR/openclaw-home/$d"
done
sudo chmod -R 777 "$SCRIPT_DIR/openclaw-home/workspace/memory"
sudo chmod -R 777 "$SCRIPT_DIR/openclaw-home/workspace/skills"
sudo chmod 666 "$SCRIPT_DIR/openclaw-home/workspace/MEMORY.md"

# NOTE: Personality files (AGENTS.md, SOUL.md, USER.md, IDENTITY.md, TOOLS.md) and
# credentials/ are intentionally NOT chowned or chmod'd — they stay host-owned (read-only to container).

info "Directory structure ready (permissions set for container UID $CONTAINER_UID)"

# --- Generate SSH keypair (if not exists) ------------------------------------

step "SSH key setup"

SSH_KEY="$SCRIPT_DIR/config/openclaw-docker-key"
if [[ -f "$SSH_KEY" ]]; then
    warn "SSH key already exists at $SSH_KEY (skipping)"
else
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "openclaw-docker"
    info "SSH keypair generated"
fi

# SSH key must be readable by container user (UID 1001) for the read-only bind mount.
# Using 640 + group ownership avoids world-readable (644 would break host ssh usage).
# The entrypoint copies it to ~/.ssh/id_ed25519 with mode 600 inside the container.
sudo chown "$(id -u):$CONTAINER_UID" "$SSH_KEY"
chmod 640 "$SSH_KEY"

# --- Setup restricted user (requires sudo) -----------------------------------

step "Host user setup"

OPENCLAW_USER="openclaw-bot"

if id "$OPENCLAW_USER" &>/dev/null; then
    warn "User '$OPENCLAW_USER' already exists (skipping)"
else
    echo ""
    warn "This step requires sudo to create a restricted user."
    read -rp "Create user '$OPENCLAW_USER' with restricted shell? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # macOS vs Linux
        if [[ "$(uname)" == "Darwin" ]]; then
            # Find next available UID
            NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
            NEXT_UID=$((NEXT_UID + 1))
            sudo dscl . -create /Users/$OPENCLAW_USER
            sudo dscl . -create /Users/$OPENCLAW_USER UserShell /usr/bin/false
            sudo dscl . -create /Users/$OPENCLAW_USER RealName "Claw Bot"
            sudo dscl . -create /Users/$OPENCLAW_USER UniqueID "$NEXT_UID"
            sudo dscl . -create /Users/$OPENCLAW_USER PrimaryGroupID 20
            sudo dscl . -create /Users/$OPENCLAW_USER NFSHomeDirectory /Users/$OPENCLAW_USER
            sudo mkdir -p /Users/$OPENCLAW_USER
            sudo chown $OPENCLAW_USER:staff /Users/$OPENCLAW_USER
            info "User created with /usr/bin/false shell (macOS)"
        else
            sudo useradd -m -s /bin/rbash "$OPENCLAW_USER"
            info "User created with rbash (Linux)"
        fi
    else
        warn "Skipped user creation. You'll need to create '$OPENCLAW_USER' manually."
    fi
fi

# --- Install SSH authorized_keys ---------------------------------------------

step "SSH authorized_keys"

if id "$OPENCLAW_USER" &>/dev/null; then
    OPENCLAW_HOME=$(eval echo "~$OPENCLAW_USER")
    SSH_DIR="$OPENCLAW_HOME/.ssh"
    PUBKEY=$(cat "$SSH_KEY.pub")
    GATEWAY_PATH="$OPENCLAW_HOME/openclaw/bin/ssh-gateway.sh"

    AUTHORIZED_LINE="command=\"$GATEWAY_PATH\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $PUBKEY"

    echo ""
    warn "This step requires sudo to write to $SSH_DIR/authorized_keys"
    read -rp "Install SSH key for '$OPENCLAW_USER'? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo mkdir -p "$SSH_DIR"
        echo "$AUTHORIZED_LINE" | sudo tee "$SSH_DIR/authorized_keys" > /dev/null
        sudo chmod 700 "$SSH_DIR"
        sudo chmod 600 "$SSH_DIR/authorized_keys"
        sudo chown -R "$OPENCLAW_USER" "$SSH_DIR"
        info "authorized_keys installed with ForceCommand"
    else
        warn "Skipped. Install manually:"
        echo "  $AUTHORIZED_LINE"
    fi

    # Symlink bin/ scripts to openclaw-bot's home
    OPENCLAW_BOT_BIN="$OPENCLAW_HOME/openclaw/bin"
    if [[ ! -L "$OPENCLAW_BOT_BIN" ]] && [[ ! -d "$OPENCLAW_BOT_BIN" ]]; then
        read -rp "Symlink scripts to $OPENCLAW_BOT_BIN? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo mkdir -p "$OPENCLAW_HOME/openclaw"
            sudo ln -sf "$SCRIPT_DIR/bin" "$OPENCLAW_BOT_BIN"
            sudo chown -h "$OPENCLAW_USER" "$OPENCLAW_BOT_BIN"
            # Also link .env so scripts can source it
            sudo ln -sf "$SCRIPT_DIR/.env" "$OPENCLAW_HOME/openclaw/.env"
            info "Scripts symlinked"
        fi
    else
        warn "Scripts path already exists at $OPENCLAW_BOT_BIN (skipping)"
    fi
else
    warn "User '$OPENCLAW_USER' doesn't exist. Skipping SSH setup."
    warn "Run this script again after creating the user."
fi

# --- Install SSH hardening config --------------------------------------------

step "SSH server hardening"

SSHD_CONF="/etc/ssh/sshd_config.d/openclaw.conf"
if [[ -f "$SSHD_CONF" ]]; then
    warn "SSH config already exists at $SSHD_CONF (skipping)"
else
    read -rp "Install SSH hardening config to $SSHD_CONF? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Generate config with correct path for this OS
        OPENCLAW_HOME=$(eval echo "~$OPENCLAW_USER")
        GATEWAY_CMD="$OPENCLAW_HOME/openclaw/bin/ssh-gateway.sh"
        cat > /tmp/openclaw-sshd.conf <<SSHD_EOF
# Claw SSH hardening - auto-generated by setup.sh
Match User $OPENCLAW_USER
    PasswordAuthentication no
    PubkeyAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    AllowAgentForwarding no
    ForceCommand $GATEWAY_CMD
SSHD_EOF
        sudo mv /tmp/openclaw-sshd.conf "$SSHD_CONF"
        info "SSH config installed (ForceCommand -> $GATEWAY_CMD)"
        # Reload SSH
        if [[ "$(uname)" == "Darwin" ]]; then
            warn "macOS: SSH config will take effect on next sshd restart"
        else
            sudo systemctl reload sshd 2>/dev/null || sudo service sshd reload 2>/dev/null || true
            info "sshd reloaded"
        fi
    else
        warn "Skipped. Install manually:"
        echo "  sudo cp $SCRIPT_DIR/config/sshd_openclaw.conf $SSHD_CONF"
    fi
fi

# --- Setup Claude Code permissions in workspace ------------------------------

step "Claude Code workspace setup"

WORKSPACE_DIR="$WORKSPACE_BASE"
if [[ -n "$REPO" ]]; then
    WORKSPACE_DIR="$WORKSPACE_DIR/$REPO"
fi

if [[ -d "$WORKSPACE_DIR" ]]; then
    CLAUDE_DIR="$WORKSPACE_DIR/.claude"
    mkdir -p "$CLAUDE_DIR"
    if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
        warn "Claude settings already exist at $CLAUDE_DIR/settings.json (skipping)"
    else
        cp "$SCRIPT_DIR/config/claude-settings.json" "$CLAUDE_DIR/settings.json"
        info "Claude Code lockdown settings installed at $CLAUDE_DIR/settings.json"
    fi
else
    warn "Workspace $WORKSPACE_DIR does not exist yet. Claude settings will need to be copied manually:"
    echo "  mkdir -p $WORKSPACE_DIR/.claude"
    echo "  cp $SCRIPT_DIR/config/claude-settings.json $WORKSPACE_DIR/.claude/settings.json"
fi

# --- Sync model ID into openclaw.json ----------------------------------------

# The model ID in openclaw.json must match what Ollama has installed.
# .env is the source of truth — sync it into openclaw.json using jq.
OPENCLAW_JSON="$SCRIPT_DIR/openclaw-home/openclaw.json"
if [[ -f "$OPENCLAW_JSON" ]]; then
    CURRENT_MODEL=$(jq -r '.models.providers.ollama.models[0].id // empty' "$OPENCLAW_JSON" 2>/dev/null)
    if [[ "$CURRENT_MODEL" != "$OLLAMA_MODEL" ]]; then
        # Generate a display name from the model ID (e.g., "qwen3.5:9b" -> "Qwen 3.5 9B")
        MODEL_NAME=$(echo "$OLLAMA_MODEL" | sed 's/:/ /; s/\b\(.\)/\u\1/g; s/b$/B/')
        jq --arg id "$OLLAMA_MODEL" --arg name "$MODEL_NAME" --arg primary "ollama/$OLLAMA_MODEL" \
            '.models.providers.ollama.models[0].id = $id | .models.providers.ollama.models[0].name = $name | .agents.defaults.model.primary = $primary' \
            "$OPENCLAW_JSON" > "${OPENCLAW_JSON}.tmp" && mv "${OPENCLAW_JSON}.tmp" "$OPENCLAW_JSON"
        info "Model synced in openclaw.json: $CURRENT_MODEL -> $OLLAMA_MODEL"
    else
        info "Model in openclaw.json already matches .env ($OLLAMA_MODEL)"
    fi
    # Ensure default model is always set to Ollama (prevents fallback to Anthropic)
    CURRENT_PRIMARY=$(jq -r '.agents.defaults.model.primary // empty' "$OPENCLAW_JSON" 2>/dev/null)
    if [[ "$CURRENT_PRIMARY" != "ollama/$OLLAMA_MODEL" ]]; then
        jq --arg primary "ollama/$OLLAMA_MODEL" \
            '.agents.defaults.model.primary = $primary' \
            "$OPENCLAW_JSON" > "${OPENCLAW_JSON}.tmp" && mv "${OPENCLAW_JSON}.tmp" "$OPENCLAW_JSON"
        info "Default model set to ollama/$OLLAMA_MODEL"
    fi
    # Sync Ollama baseUrl (native mode uses host.docker.internal, docker mode uses ollama)
    CURRENT_BASE_URL=$(jq -r '.models.providers.ollama.baseUrl // empty' "$OPENCLAW_JSON" 2>/dev/null)
    if [[ "$CURRENT_BASE_URL" != "$OLLAMA_HOST" ]]; then
        jq --arg url "$OLLAMA_HOST" \
            '.models.providers.ollama.baseUrl = $url' \
            "$OPENCLAW_JSON" > "${OPENCLAW_JSON}.tmp" && mv "${OPENCLAW_JSON}.tmp" "$OPENCLAW_JSON"
        info "Ollama baseUrl synced: $CURRENT_BASE_URL -> $OLLAMA_HOST"
    fi
fi

# --- Build & start Docker stack ----------------------------------------------

step "Docker build & start"

echo "Claw version: $OPENCLAW_VERSION"
echo "Default repo: ${REPO:-'(not set)'}"
echo ""
read -rp "Build and start Docker containers? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Export vars for docker-compose interpolation
    export OPENCLAW_VERSION
    export REPO

    # In native mode, ensure Ollama is running on the host before starting containers
    if [[ "$OLLAMA_MODE" == "native" ]]; then
        if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
            info "Starting Ollama natively..."
            OLLAMA_HOST= ollama serve &>/dev/null &
            for i in $(seq 1 30); do
                curl -sf http://localhost:11434/api/tags &>/dev/null && break
                sleep 1
            done
        fi
        if curl -sf http://localhost:11434/api/tags &>/dev/null; then
            info "Ollama is running natively (Metal GPU enabled)"
        else
            warn "Ollama not responding at localhost:11434 — start manually: ollama serve"
        fi
    fi

    # Build and start — in docker mode, activate the ollama profile
    COMPOSE_PROFILES=""
    if [[ "$OLLAMA_MODE" == "docker" ]]; then
        COMPOSE_PROFILES="--profile docker-ollama"
    fi

    cd "$SCRIPT_DIR/docker"
    docker compose $COMPOSE_PROFILES build --build-arg OPENCLAW_VERSION="$OPENCLAW_VERSION"
    docker compose $COMPOSE_PROFILES up -d
    info "Containers started"

    # Wait for gateway to become healthy (generates auth token on first start)
    echo ""
    info "Waiting for gateway to become healthy..."
    for i in $(seq 1 90); do
        if curl -sf http://localhost:3000/health &>/dev/null; then
            info "Gateway is healthy"
            break
        fi
        if [[ $i -eq 90 ]]; then
            warn "Gateway not healthy after 90s — check logs with: docker logs zupee-claw"
        fi
        sleep 1
    done

    # Extract gateway token — the gateway generates it on first start and writes
    # it back to openclaw.json. Wait for the token to appear.
    if curl -sf http://localhost:3000/health &>/dev/null; then
        GATEWAY_TOKEN=""
        info "Waiting for gateway to generate auth token..."
        for i in $(seq 1 30); do
            GATEWAY_TOKEN=$(docker exec zupee-claw cat /home/openclaw/.openclaw/openclaw.json 2>/dev/null \
                | jq -r '.gateway.auth.token // empty' 2>/dev/null)
            if [[ -n "$GATEWAY_TOKEN" ]]; then
                break
            fi
            sleep 1
        done
        if [[ -n "$GATEWAY_TOKEN" ]]; then
            # Use URL fragment (#token=) instead of query param (?token=).
            # Fragments are never sent to the server, never logged, and never
            # appear in HTTP Referer headers — but browser JS can still read
            # them for auto-pairing. The Control UI imports the token from the
            # fragment into sessionStorage and strips it from the URL.
            GATEWAY_URL="http://localhost:3000/#token=$GATEWAY_TOKEN"
            info "Web UI ready at $GATEWAY_URL"
            echo ""
            echo "  Auth Token: $GATEWAY_TOKEN"
            echo ""
            # Open browser with token in fragment for frictionless + secure pairing
            if command -v xdg-open &>/dev/null; then
                xdg-open "$GATEWAY_URL" 2>/dev/null &
            elif command -v open &>/dev/null; then
                open "$GATEWAY_URL" 2>/dev/null &
            fi
            # Wait for browser to connect. With #token= in the URL, the browser
            # authenticates directly (device goes straight to "paired", no pending request).
            # Without a token, a pending request appears that needs manual approval.
            info "Waiting for browser to connect..."
            PAIRED=false
            for i in $(seq 1 120); do
                DEVICES_JSON=$(docker exec zupee-claw openclaw devices list --json 2>/dev/null)
                # Check if browser already paired (token-based auth — no pending step)
                PAIRED_DEVICE=$(echo "$DEVICES_JSON" \
                    | jq -r '.paired[] | select(.clientId == "openclaw-control-ui") | .deviceId // empty' 2>/dev/null | head -1)
                if [[ -n "$PAIRED_DEVICE" ]]; then
                    info "Browser connected!"
                    PAIRED=true
                    break
                fi
                # Check for pending request (no-token flow — needs approval)
                REQUEST_ID=$(echo "$DEVICES_JSON" \
                    | jq -r '.pending[] | select(.clientId == "openclaw-control-ui") | .requestId // empty' 2>/dev/null | head -1)
                if [[ -n "$REQUEST_ID" ]]; then
                    docker exec zupee-claw openclaw devices approve "$REQUEST_ID" 2>/dev/null
                    info "Browser paired!"
                    PAIRED=true
                    break
                fi
                sleep 1
            done
            if [[ "$PAIRED" != "true" ]]; then
                warn "No browser connection within 2 minutes. Open the URL manually:"
                echo "  $GATEWAY_URL"
            fi
        else
            warn "Gateway token not generated after 30s"
            warn "Retrieve token: docker exec zupee-claw jq -r .gateway.auth.token ~/.openclaw/openclaw.json"
        fi
    fi

    # Pull model
    echo ""
    read -rp "Pull $OLLAMA_MODEL model now? (this may take a while) [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [[ "$OLLAMA_MODE" == "native" ]]; then
            # Native mode: pull directly (host has internet access)
            info "Pulling $OLLAMA_MODEL..."
            # Unset OLLAMA_HOST — it's set to host.docker.internal for the container,
            # but the native ollama CLI needs localhost (its default).
            if OLLAMA_HOST= ollama pull "$OLLAMA_MODEL"; then
                info "$OLLAMA_MODEL ready"
            else
                error "Failed to pull $OLLAMA_MODEL"
            fi
        else
            # Docker mode: Ollama is air-gapped, temporarily connect to squid-egress
            info "Connecting Ollama to internet for model download..."
            docker network connect zupee-claw_squid-egress zupee-ollama 2>/dev/null || true
            info "Pulling $OLLAMA_MODEL... (this may take several minutes)"
            if docker compose $COMPOSE_PROFILES exec ollama ollama pull "$OLLAMA_MODEL"; then
                info "$OLLAMA_MODEL ready"
            else
                error "Failed to pull $OLLAMA_MODEL — check network or try again later"
            fi
            info "Disconnecting Ollama from internet..."
            docker network disconnect zupee-claw_squid-egress zupee-ollama 2>/dev/null || true
        fi
    else
        if [[ "$OLLAMA_MODE" == "native" ]]; then
            warn "Pull later with: ollama pull $OLLAMA_MODEL"
        else
            warn "Pull later with:"
            echo "  docker network connect zupee-claw_squid-egress zupee-ollama"
            echo "  docker exec zupee-ollama ollama pull $OLLAMA_MODEL"
            echo "  docker network disconnect zupee-claw_squid-egress zupee-ollama"
        fi
    fi

    cd "$SCRIPT_DIR"
else
    warn "Skipped. Start manually:"
    echo "  cd $SCRIPT_DIR/docker && docker compose up -d --build"
fi

# --- Verification ------------------------------------------------------------

step "Verification"

echo ""
# Check containers
if docker ps --format '{{.Names}}' | grep -q zupee-claw; then
    info "Claw container: running"
else
    warn "Claw container: not running"
fi

if [[ "$OLLAMA_MODE" == "native" ]]; then
    if curl -sf http://localhost:11434/api/tags &>/dev/null; then
        info "Ollama (native): running with Metal GPU"
    else
        warn "Ollama (native): not responding at localhost:11434"
    fi
else
    if docker ps --format '{{.Names}}' | grep -q zupee-ollama; then
        info "Ollama container: running"
    else
        warn "Ollama container: not running"
    fi
fi

if docker ps --format '{{.Names}}' | grep -q zupee-squid; then
    info "Squid proxy: running"
else
    warn "Squid proxy: not running"
fi

# Check web UI
if curl -sf http://localhost:3000/health &>/dev/null; then
    info "Web UI: http://localhost:3000 (healthy)"
else
    warn "Web UI: not responding yet (may still be starting)"
fi

# Check Slack tokens
SLACK_BOT=$(grep '^SLACK_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
SLACK_APP=$(grep '^SLACK_APP_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
if [[ -n "$SLACK_BOT" ]] && [[ -n "$SLACK_APP" ]]; then
    info "Slack tokens: configured (Socket Mode)"
elif [[ -n "$SLACK_BOT" ]]; then
    warn "Slack: SLACK_BOT_TOKEN set but SLACK_APP_TOKEN missing (Socket Mode requires both)"
else
    warn "Slack: not configured (set SLACK_BOT_TOKEN + SLACK_APP_TOKEN in .env)"
fi

# Check SSH key
if [[ -f "$SSH_KEY" ]]; then
    info "SSH key: $SSH_KEY"
else
    warn "SSH key: missing"
fi

# Extract gateway auth token using jq for reliable JSON parsing
GATEWAY_TOKEN=""
if docker ps --format '{{.Names}}' | grep -q zupee-claw; then
    GATEWAY_TOKEN=$(docker exec zupee-claw cat /home/openclaw/.openclaw/openclaw.json 2>/dev/null \
        | jq -r '.gateway.auth.token // empty' 2>/dev/null)
    if [[ -n "$GATEWAY_TOKEN" ]]; then
        info "Gateway auth token: extracted"
    else
        warn "Gateway auth token: not found (gateway may not have started yet)"
    fi
fi

# Summary
step "Setup Complete"
echo ""
echo "  Config:      $SCRIPT_DIR/.env"
echo "  Version:     Claw $OPENCLAW_VERSION"
echo "  Repo:        ${REPO:-'(not set)'}"
echo "  Agent files: $SCRIPT_DIR/openclaw-home/workspace/"
echo "  Logs:        $SCRIPT_DIR/logs/"
echo ""
if [[ -n "$GATEWAY_TOKEN" ]]; then
echo "  Web UI:      http://localhost:3000/#token=$GATEWAY_TOKEN"
echo ""
echo "  (retrieve token later: docker exec zupee-claw jq -r .gateway.auth.token ~/.openclaw/openclaw.json)"
else
echo "  Web UI:      http://localhost:3000"
echo ""
echo "  Retrieve token: docker exec zupee-claw jq -r .gateway.auth.token ~/.openclaw/openclaw.json"
fi
echo ""
echo "  To tear down: $SCRIPT_DIR/cleanup.sh"
echo ""
