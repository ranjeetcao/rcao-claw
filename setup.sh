#!/bin/bash
set -euo pipefail

# =============================================================================
# Zupee Claw - End-to-End Setup
# Provisions everything needed to run Claw in Docker with SSH gateway
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse flags -------------------------------------------------------------
AUTO_YES=false
AUTO_ROLE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) AUTO_YES=true; shift ;;
        --role)   AUTO_ROLE="$2"; shift 2 ;;
        --help|-h) echo "Usage: $0 [--yes] [--role developer|qa|marketing]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Auto-confirm wrapper: returns 'y' in --yes mode, else prompts user
ask() {
    if [[ "$AUTO_YES" == "true" ]]; then
        echo "y"
    else
        local reply
        read -rp "$1" reply
        echo "$reply"
    fi
}

# Like ask(), but returns 'n' when running --yes without passwordless sudo.
# Use for steps that require sudo (user creation, SSH config, etc.)
ask_sudo() {
    if [[ "$AUTO_YES" == "true" ]]; then
        if sudo -n true 2>/dev/null; then
            echo "y"
        else
            warn "Skipping (sudo requires password, running non-interactive)"
            echo "n"
        fi
    else
        local reply
        read -rp "$1" reply
        echo "$reply"
    fi
}

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
_WORKSPACE=$(grep '^WORKSPACE=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
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

# Resolve WORKSPACE path (expand ~ to $HOME, persist absolute path to .env)
if [[ -n "${_WORKSPACE:-}" ]]; then
    WORKSPACE="${_WORKSPACE/#\~/$HOME}"
else
    WORKSPACE="$HOME/workspace/my-project"
fi
# Persist the resolved absolute path so openclaw-bot (different $HOME) can use it
if grep -q "^WORKSPACE=" "$ENV_FILE" 2>/dev/null; then
    sed -i.bak "s|^WORKSPACE=.*|WORKSPACE=$WORKSPACE|" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
else
    echo "WORKSPACE=$WORKSPACE" >> "$ENV_FILE"
fi

# Fallback for OLLAMA_MODEL
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma4:e2b}"
# Fallback for model memory (GiB) — 10 GiB for gemma4:e2b default
OLLAMA_MODEL_MEM="${OLLAMA_MODEL_MEM:-10}"

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

# Helper to persist a variable to .env for docker-compose interpolation
persist_env_var() {
    local name="$1" val="$2"
    if grep -q "^${name}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|^${name}=.*|${name}=${val}|" "$ENV_FILE"
    else
        echo "${name}=${val}" >> "$ENV_FILE"
    fi
}

# Persist resource limits and mode to .env
persist_env_var CLAW_MEM "$CLAW_MEM"
persist_env_var CLAW_CPUS "$CLAW_CPUS"
persist_env_var OLLAMA_HOST "$OLLAMA_HOST"
persist_env_var OLLAMA_MODE "$OLLAMA_MODE"
if [[ "$OLLAMA_MODE" == "docker" ]]; then
    persist_env_var OLLAMA_MEM "$OLLAMA_MEM"
    persist_env_var OLLAMA_CPUS "$OLLAMA_CPUS"
fi
rm -f "${ENV_FILE}.bak"
info "Resource limits written to .env"

# --- Select role & create directories ----------------------------------------

step "Role selection"

OPENCLAW_HOME="$HOME/.openclaw"
export OPENCLAW_HOME

# Available roles from personality/ directory
AVAILABLE_ROLES=""
for d in "$SCRIPT_DIR/personality"/*/; do
    role=$(basename "$d")
    [[ "$role" == "shared" ]] && continue
    AVAILABLE_ROLES="$AVAILABLE_ROLES $role"
done
AVAILABLE_ROLES="${AVAILABLE_ROLES# }"

echo ""
echo "  Available roles:$( for r in $AVAILABLE_ROLES; do echo -n " [$r]"; done )"
echo ""
if [[ -n "$AUTO_ROLE" ]]; then
    ROLE="$AUTO_ROLE"
else
    read -rp "Select your role: " ROLE
fi

# Validate role
if [[ -z "$ROLE" ]] || [[ ! -d "$SCRIPT_DIR/personality/$ROLE" ]]; then
    error "Invalid role '$ROLE'. Available: $AVAILABLE_ROLES"
    exit 1
fi
info "Role selected: $ROLE"

step "Creating directories"

# Create log directories
mkdir -p "$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR/logs/squid"
# Squid runs as UID 13 (proxy), container runs as UID 1001 — both need write access.
# Using 775 with current user ownership; Docker handles UID mapping for writes.
chmod 775 "$SCRIPT_DIR/logs/squid"
chmod 775 "$SCRIPT_DIR/logs"

# Create OpenClaw home at ~/.openclaw (outside the repo)
mkdir -p "$OPENCLAW_HOME/workspace"

# If ~/.openclaw has container-owned files (UID 1001), delete and recreate.
# This avoids macOS TCC popups from find/chown on Docker-owned files.
if [[ -d "$OPENCLAW_HOME" ]]; then
    # Try removing container-created subdirs that may have wrong ownership
    rm -rf "$OPENCLAW_HOME/agents" "$OPENCLAW_HOME/canvas" "$OPENCLAW_HOME/devices" \
           "$OPENCLAW_HOME/identity" "$OPENCLAW_HOME/sandboxes" "$OPENCLAW_HOME/tasks" \
           "$OPENCLAW_HOME/flows" "$OPENCLAW_HOME/memory" "$OPENCLAW_HOME/logs" \
           "$OPENCLAW_HOME/cron" 2>/dev/null || true
fi

# Ensure directory exists and is writable
mkdir -p "$OPENCLAW_HOME/workspace"
chmod -R 755 "$OPENCLAW_HOME" 2>/dev/null || true

# Copy personality files: shared + role-specific → ~/.openclaw/workspace/
info "Installing personality files for role: $ROLE"
for f in "$SCRIPT_DIR/personality/shared"/*.md; do
    [[ -f "$f" ]] && cp "$f" "$OPENCLAW_HOME/workspace/"
done
for f in "$SCRIPT_DIR/personality/$ROLE"/*.md; do
    [[ -f "$f" ]] && cp "$f" "$OPENCLAW_HOME/workspace/"
done
info "Personality files installed at $OPENCLAW_HOME/workspace/"

# Seed minimal openclaw.json if missing — the gateway needs this to start.
# openclaw onboard will configure it properly after the gateway is up.
if [[ ! -f "$OPENCLAW_HOME/openclaw.json" ]]; then
    cat > "$OPENCLAW_HOME/openclaw.json" << SEED_EOF
{
  "gateway": {
    "mode": "local",
    "bind": "custom",
    "customBindHost": "0.0.0.0",
    "port": 3000
  }
}
SEED_EOF
    info "Seeded minimal openclaw.json"
fi

# Persist OPENCLAW_HOME for docker-compose volume mount interpolation.
# Note: this is also loaded into the container via env_file, but OpenClaw
# inside the container ignores it (it uses ~/.openclaw by default).
persist_env_var OPENCLAW_HOME "$OPENCLAW_HOME"

info "Directory structure ready"

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
sudo chown "$(id -u):1001" "$SSH_KEY" 2>/dev/null || true
chmod 640 "$SSH_KEY" 2>/dev/null || true

# --- Install SSH authorized_keys for current user ----------------------------
# No separate bot user needed — the Docker SSH key is added to the developer's
# own authorized_keys with ForceCommand, which restricts it to gateway scripts only.
# Other SSH keys (normal login) are unaffected.

step "SSH authorized_keys"

SSH_DIR="$HOME/.ssh"
PUBKEY=$(cat "$SSH_KEY.pub")
GATEWAY_PATH="$SCRIPT_DIR/bin/ssh-gateway.sh"

# ForceCommand line — restricts this specific key to only run the gateway
AUTHORIZED_LINE="command=\"$GATEWAY_PATH\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $PUBKEY"

# Create .ssh dir if missing
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Add the key if not already present (don't duplicate on re-runs)
if ! grep -qF "openclaw-docker" "$SSH_DIR/authorized_keys" 2>/dev/null; then
    echo "$AUTHORIZED_LINE" >> "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    info "SSH key added to $SSH_DIR/authorized_keys with ForceCommand"
else
    warn "SSH key already in authorized_keys (skipping)"
fi

# Create openclaw runtime dir (for logs, rate-limit files)
mkdir -p "$HOME/openclaw/logs"

# Symlink bin/ and .env if not already present
OPENCLAW_BIN="$HOME/openclaw/bin"
if [[ ! -L "$OPENCLAW_BIN" ]]; then
    ln -sf "$SCRIPT_DIR/bin" "$OPENCLAW_BIN"
    info "Scripts symlinked to $OPENCLAW_BIN"
fi
if [[ ! -L "$HOME/openclaw/.env" ]]; then
    ln -sf "$SCRIPT_DIR/.env" "$HOME/openclaw/.env"
fi

# Create Claude Code auth helper — reads OAuth token from .credentials-cache.
# SSH sessions can't access macOS Keychain, so claude uses this helper via --settings.
AUTH_HELPER="$HOME/openclaw/claude-auth-helper.sh"
cat > "$AUTH_HELPER" << 'AUTHEOF'
#!/bin/bash
cat "$HOME/.claude/.credentials-cache" 2>/dev/null | tr -d '[:space:]'
AUTHEOF
chmod +x "$AUTH_HELPER"

# Refresh .credentials-cache from Keychain (only works in GUI context — e.g., during setup)
if [[ "$(uname)" == "Darwin" ]]; then
    _KEYCHAIN_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -n "$_KEYCHAIN_TOKEN" ]]; then
        echo -n "$_KEYCHAIN_TOKEN" > "$HOME/.claude/.credentials-cache"
        chmod 640 "$HOME/.claude/.credentials-cache"
        info "Claude Code credentials refreshed from Keychain"
    fi
fi

# --- Ensure Remote Login is enabled (macOS) -----------------------------------
# SSH must be enabled for the container to reach the host via SSH gateway.

step "SSH server"

if [[ "$(uname)" == "Darwin" ]]; then
    if ! sudo systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
        confirm=$(ask_sudo "Enable macOS Remote Login (required for SSH gateway)? [y/N] ")
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sudo systemsetup -setremotelogin on 2>/dev/null || true
            info "macOS Remote Login enabled"
        fi
    else
        info "macOS Remote Login: already enabled"
    fi
fi

# --- Setup Claude Code permissions in workspace ------------------------------

step "Claude Code workspace setup"

if [[ -d "$WORKSPACE" ]]; then
    CLAUDE_DIR="$WORKSPACE/.claude"
    mkdir -p "$CLAUDE_DIR"
    if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
        warn "Claude settings already exist at $CLAUDE_DIR/settings.json (skipping)"
    else
        cp "$SCRIPT_DIR/config/claude-settings.json" "$CLAUDE_DIR/settings.json"
        info "Claude Code lockdown settings installed at $CLAUDE_DIR/settings.json"
    fi
else
    warn "Workspace $WORKSPACE does not exist yet. Claude settings will need to be copied manually:"
    echo "  mkdir -p $WORKSPACE/.claude"
    echo "  cp $SCRIPT_DIR/config/claude-settings.json $WORKSPACE/.claude/settings.json"
fi

# NOTE: Model configuration is handled by `openclaw onboard` after the gateway
# starts (see below). Do NOT manually edit openclaw.json — the gateway owns it.

# --- Build & start Docker stack ----------------------------------------------

step "Docker build & start"

echo "Claw version: $OPENCLAW_VERSION"
echo "Workspace:    $WORKSPACE"
echo ""
confirm=$(ask "Build and start Docker containers? [y/N] ")
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Export vars for docker-compose interpolation
    export OPENCLAW_VERSION

    # In native mode, ensure Ollama is running on the host before starting containers
    if [[ "$OLLAMA_MODE" == "native" ]]; then
        if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
            info "Starting Ollama natively..."
            OLLAMA_HOST= OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1 ollama serve &>/dev/null &
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

    # Run openclaw onboard BEFORE starting the gateway.
    # The gateway needs a valid config to start, and onboard creates it properly.
    # We use `docker compose run --rm --entrypoint ""` to run onboard as a one-shot
    # command without triggering the gateway entrypoint.
    info "Configuring OpenClaw with Ollama ($OLLAMA_MODEL)..."
    # Pre-create directories that onboard needs to write to.
    # On macOS Docker Desktop, directories created by Docker have restrictive
    # xattrs (com.docker.grpcfuse.ownership) that override chmod. Creating them
    # from the host side avoids this.
    mkdir -p "$OPENCLAW_HOME/agents/main/agent" \
             "$OPENCLAW_HOME/agents/main/sessions" \
             "$OPENCLAW_HOME/credentials" \
             "$OPENCLAW_HOME/workspace"
    # Note: dirs are pre-created from host side above, so Docker xattrs
    # are not present. No xattr stripping needed.
    chmod -R 770 "$OPENCLAW_HOME" 2>/dev/null || true
    if docker compose $COMPOSE_PROFILES run --rm -T --entrypoint "" \
        -e OLLAMA_HOST="$OLLAMA_HOST" -e OPENCLAW_HOME= \
        openclaw \
        openclaw onboard \
            --non-interactive \
            --auth-choice ollama \
            --custom-base-url "$OLLAMA_HOST" \
            --custom-model-id "$OLLAMA_MODEL" \
            --gateway-auth token \
            --gateway-bind custom \
            --gateway-port 3000 \
            --mode local \
            --accept-risk \
            --skip-health; then
        info "OpenClaw configured with ollama/$OLLAMA_MODEL"
    else
        warn "Onboarding returned non-zero — check with: docker exec zupee-claw openclaw doctor"
    fi

    # Apply agent defaults (timeout for CPU inference, thinking level)
    docker compose $COMPOSE_PROFILES run --rm -T --entrypoint "" \
        -e OPENCLAW_HOME= \
        openclaw openclaw config set agents.defaults.timeoutSeconds 300 2>/dev/null || true
    docker compose $COMPOSE_PROFILES run --rm -T --entrypoint "" \
        -e OPENCLAW_HOME= \
        openclaw openclaw config set agents.defaults.thinkingDefault low 2>/dev/null || true

    # Tighten permissions after onboard — only owner + group (container UID 1001) need access
    chmod -R 755 "$OPENCLAW_HOME" 2>/dev/null || true
    chmod 600 "$OPENCLAW_HOME/openclaw.json" 2>/dev/null || true

    # Start the gateway now that config is ready
    docker compose $COMPOSE_PROFILES up -d
    info "Containers started"

    # Wait for gateway to become healthy
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
            # Open browser (skip in non-interactive mode)
            if [[ "$AUTO_YES" != "true" ]]; then
                if command -v xdg-open &>/dev/null; then
                    xdg-open "$GATEWAY_URL" 2>/dev/null &
                elif command -v open &>/dev/null; then
                    open "$GATEWAY_URL" 2>/dev/null &
                fi
            fi
            # Wait for browser to connect (skip in non-interactive mode)
            if [[ "$AUTO_YES" == "true" ]]; then
                info "Skipping browser pairing (non-interactive mode)"
                info "Open manually: $GATEWAY_URL"
            else
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
            fi  # end AUTO_YES skip
        else
            warn "Gateway token not generated after 30s"
            warn "Retrieve token: docker exec zupee-claw jq -r .gateway.auth.token ~/.openclaw/openclaw.json"
        fi
    fi

    # Pull model
    echo ""
    confirm=$(ask "Pull $OLLAMA_MODEL model now? (this may take a while) [y/N] ")
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
SLACK_BOT=$(grep '^SLACK_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
SLACK_APP=$(grep '^SLACK_APP_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
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
echo "  Workspace:   $WORKSPACE"
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
