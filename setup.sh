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
OPENCLAW_VERSION=$(grep '^OPENCLAW_VERSION=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
REPO=$(grep '^REPO=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")

# --- Pre-flight checks -------------------------------------------------------

step "Pre-flight checks"

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

# Detect system resources and calculate container limits
TOTAL_CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
TOTAL_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || \
    sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1048576)}' || echo 8192)

if [[ "$TOTAL_MEM_MB" -lt 6144 ]]; then
    warn "Only ${TOTAL_MEM_MB}MB RAM detected. Minimum recommended: 6GB."
fi

# Calculate resource limits (leave headroom for host OS)
export OLLAMA_CPUS=$(awk "BEGIN {v=$TOTAL_CPUS * 0.6; if (v < 0.5) v = 0.5; printf \"%.1f\", v}")
export OLLAMA_MEM="$(( TOTAL_MEM_MB * 50 / 100 ))M"
export CLAW_CPUS=$(awk "BEGIN {v=$TOTAL_CPUS * 0.4; if (v < 0.25) v = 0.25; printf \"%.1f\", v}")
export CLAW_MEM="$(( TOTAL_MEM_MB * 20 / 100 ))M"
info "System: ${TOTAL_CPUS} CPUs, ${TOTAL_MEM_MB}MB RAM"
info "  Ollama limits: ${OLLAMA_CPUS} CPUs, ${OLLAMA_MEM}"
info "  Claw limits:   ${CLAW_CPUS} CPUs, ${CLAW_MEM}"

# --- Create host directories -------------------------------------------------

step "Creating directories"

mkdir -p "$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR/logs/squid"
mkdir -p "$SCRIPT_DIR/openclaw-home/agents/main/sessions"
mkdir -p "$SCRIPT_DIR/openclaw-home/credentials"
mkdir -p "$SCRIPT_DIR/openclaw-home/skills"
mkdir -p "$SCRIPT_DIR/openclaw-home/workspace/memory"
mkdir -p "$SCRIPT_DIR/openclaw-home/workspace/skills"

# Create MEMORY.md if missing (docker bind-mounts it as a file)
touch "$SCRIPT_DIR/openclaw-home/workspace/MEMORY.md"

# Fix permissions for container user (UID 1001 inside container)
# Squid runs as proxy user (UID 13) — needs write access to mounted log dir
chmod 777 "$SCRIPT_DIR/logs/squid"
# Logs dir writable by container user
chmod 777 "$SCRIPT_DIR/logs"
# openclaw-home writable by container (gateway writes temp files, auto-migrates config)
chmod -R a+rwX "$SCRIPT_DIR/openclaw-home"

info "Directory structure ready (permissions set for container access)"

# --- Generate SSH keypair (if not exists) ------------------------------------

step "SSH key setup"

SSH_KEY="$SCRIPT_DIR/config/openclaw-docker-key"
if [[ -f "$SSH_KEY" ]]; then
    warn "SSH key already exists at $SSH_KEY (skipping)"
else
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "openclaw-docker"
    info "SSH keypair generated"
fi

# SSH key needs to be readable by container user (mounted read-only, but must be world-readable
# since container UID differs from host UID). The entrypoint copies it to a secure location with 600.
chmod 644 "$SSH_KEY"

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

WORKSPACE_DIR="$HOME/workspace"
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

    cd "$SCRIPT_DIR/docker"
    docker compose build --build-arg OPENCLAW_VERSION="$OPENCLAW_VERSION"
    docker compose up -d
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

    # Auto-approve CLI device pairing so gateway commands work immediately
    if curl -sf http://localhost:3000/health &>/dev/null; then
        info "Approving CLI device pairing..."
        docker compose exec openclaw openclaw devices approve --latest 2>/dev/null || true
    fi

    # Pull Qwen model
    echo ""
    read -rp "Pull Qwen 3.5 model now? (this may take a while) [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        info "Pulling Qwen 3.5... (this may take several minutes)"
        docker compose exec ollama ollama pull qwen3.5
        info "Qwen 3.5 ready"
    else
        warn "Pull later with: docker compose exec ollama ollama pull qwen3.5"
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

if docker ps --format '{{.Names}}' | grep -q zupee-ollama; then
    info "Ollama container: running"
else
    warn "Ollama container: not running"
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

# Extract gateway auth token
GATEWAY_TOKEN=""
if docker ps --format '{{.Names}}' | grep -q zupee-claw; then
    GATEWAY_TOKEN=$(docker exec zupee-claw cat /home/openclaw/.openclaw/openclaw.json 2>/dev/null \
        | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
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
if [[ -n "$GATEWAY_TOKEN" ]]; then
echo "  Web UI:      http://localhost:3000/?token=$GATEWAY_TOKEN"
echo "  Auth Token:  $GATEWAY_TOKEN"
else
echo "  Web UI:      http://localhost:3000"
fi
echo "  Agent files: $SCRIPT_DIR/openclaw-home/workspace/"
echo "  Logs:        $SCRIPT_DIR/logs/"
echo ""
echo "  Next steps:"
echo "    1. Open the Web UI URL above in your browser"
echo "    2. Approve browser pairing:"
echo "       docker exec zupee-claw openclaw devices approve --latest"
echo ""
echo "  To tear down: $SCRIPT_DIR/cleanup.sh"
echo ""
