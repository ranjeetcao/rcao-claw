#!/bin/bash
set -euo pipefail

# =============================================================================
# Zupee Claw - End-to-End Cleanup
# Tears down everything provisioned by setup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse .env safely (no source — prevents code injection)
ENV_FILE="$SCRIPT_DIR/.env"
OPENCLAW_VERSION=$(grep '^OPENCLAW_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
REPO=$(grep '^REPO=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
_WORKSPACE_DIR=$(grep '^WORKSPACE_DIR=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true)

# Resolve WORKSPACE_DIR (expand ~ to $HOME), fallback to $HOME/workspace
if [[ -n "${_WORKSPACE_DIR:-}" ]]; then
    WORKSPACE_BASE="${_WORKSPACE_DIR/#\~/$HOME}"
else
    WORKSPACE_BASE="$HOME/workspace"
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }
step()  { echo -e "\n${GREEN}=== $* ===${NC}"; }

echo ""
echo -e "${RED}========================================${NC}"
echo -e "${RED}  Zupee Claw - Full Cleanup${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo "This will remove:"
echo "  - Docker containers (zupee-claw, zupee-ollama, zupee-squid)"
echo "  - Docker images and volumes"
echo "  - SSH key, authorized_keys, sshd config"
echo "  - Host user: openclaw-bot"
echo "  - Claude Code settings from workspace"
echo ""
echo -e "${YELLOW}Agent data (openclaw-home/) and logs will be KEPT unless you choose to delete them.${NC}"
echo ""
read -rp "Proceed with cleanup? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Stop & remove Docker containers ----------------------------------------

step "Docker cleanup"

# Always attempt docker compose down — handles both running and stopped containers.
if docker compose -f "$SCRIPT_DIR/docker/docker-compose.yml" down --rmi local --volumes --remove-orphans 2>&1; then
    info "Containers, images, and volumes removed"
else
    warn "Docker compose down had issues (containers may not have been running)"
fi

# Remove dangling images
docker image prune -f --filter "label=com.docker.compose.project=zupee-claw" 2>/dev/null || true
info "Docker cleanup done"

# --- Remove SSH config -------------------------------------------------------

step "SSH cleanup"

SSHD_CONF="/etc/ssh/sshd_config.d/openclaw.conf"
if [[ -f "$SSHD_CONF" ]]; then
    read -rp "Remove SSH hardening config ($SSHD_CONF)? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo rm -f "$SSHD_CONF"
        if [[ "$(uname)" != "Darwin" ]]; then
            sudo systemctl reload sshd 2>/dev/null || sudo service sshd reload 2>/dev/null || true
        fi
        info "SSH config removed"
    else
        warn "Kept $SSHD_CONF"
    fi
else
    info "No SSH config found at $SSHD_CONF"
fi

# --- Remove SSH key ----------------------------------------------------------

SSH_KEY="$SCRIPT_DIR/config/openclaw-docker-key"
if [[ -f "$SSH_KEY" ]]; then
    read -rp "Remove SSH keypair? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$SSH_KEY" "$SSH_KEY.pub"
        info "SSH keypair removed"
    else
        warn "Kept SSH keypair"
    fi
else
    info "No SSH keypair found"
fi

# --- Remove host user --------------------------------------------------------

step "Host user cleanup"

OPENCLAW_USER="openclaw-bot"
if id "$OPENCLAW_USER" &>/dev/null; then
    read -rp "Remove user '$OPENCLAW_USER' and their home directory? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            OPENCLAW_HOME=$(dscl . -read /Users/$OPENCLAW_USER NFSHomeDirectory 2>/dev/null | awk '{print $2}')
            sudo dscl . -delete /Users/$OPENCLAW_USER
            if [[ -n "$OPENCLAW_HOME" ]] && [[ -d "$OPENCLAW_HOME" ]]; then
                sudo rm -rf "$OPENCLAW_HOME"
            fi
            info "User removed (macOS)"
        else
            sudo userdel -r "$OPENCLAW_USER" 2>/dev/null || sudo userdel "$OPENCLAW_USER"
            info "User removed (Linux)"
        fi
    else
        warn "Kept user '$OPENCLAW_USER'"
    fi
else
    info "User '$OPENCLAW_USER' does not exist"
fi

# --- Remove Claude Code settings from workspace ------------------------------

step "Claude Code workspace cleanup"

WORKSPACE_DIR="$WORKSPACE_BASE"
if [[ -n "$REPO" ]]; then
    WORKSPACE_DIR="$WORKSPACE_DIR/$REPO"
fi

CLAUDE_SETTINGS="$WORKSPACE_DIR/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    read -rp "Remove Claude Code settings from $WORKSPACE_DIR/.claude/? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$CLAUDE_SETTINGS"
        rmdir "$WORKSPACE_DIR/.claude" 2>/dev/null || true
        info "Claude settings removed"
    else
        warn "Kept Claude settings"
    fi
else
    info "No Claude settings found at $CLAUDE_SETTINGS"
fi

# --- Agent data & logs (optional) -------------------------------------------

step "Agent data & logs"

# Reclaim ownership of files created by the container (UID 1001) so we can delete them.
# Without this, rm fails on container-owned files like devices/paired.json.
if [[ -d "$SCRIPT_DIR/openclaw-home" ]]; then
    CONTAINER_OWNED=$(find "$SCRIPT_DIR/openclaw-home" "$SCRIPT_DIR/logs" -not -user "$(id -u)" 2>/dev/null | head -1)
    if [[ -n "$CONTAINER_OWNED" ]]; then
        warn "Some files are owned by the container user (UID 1001). Need sudo to reclaim."
        if sudo chown -R "$(id -u):$(id -g)" "$SCRIPT_DIR/openclaw-home" "$SCRIPT_DIR/logs"; then
            info "Reclaimed file ownership"
        else
            error "Failed to reclaim file ownership. Run manually:"
            echo "  sudo chown -R \$(id -u):\$(id -g) $SCRIPT_DIR/openclaw-home $SCRIPT_DIR/logs"
            echo ""
            read -rp "Continue cleanup anyway? (some deletes may fail) [y/N] " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "Aborted. Fix ownership first, then re-run cleanup."
                exit 1
            fi
        fi
    fi
fi

# Gateway runtime dirs (devices, sessions, sandboxes, etc.) — always clean these
for d in agents canvas devices identity sandboxes tasks; do
    if [[ -d "$SCRIPT_DIR/openclaw-home/$d" ]]; then
        rm -rf "$SCRIPT_DIR/openclaw-home/$d" 2>/dev/null || \
            warn "Could not fully remove openclaw-home/$d (permission issue)"
    fi
done
info "Gateway runtime data cleaned (devices, sessions, etc.)"

if [[ -d "$SCRIPT_DIR/openclaw-home/workspace" ]]; then
    echo ""
    echo "Agent data includes: memory, skills, credentials"
    echo "Location: $SCRIPT_DIR/openclaw-home/"
    read -rp "Delete agent data? This is IRREVERSIBLE. [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        read -rp "Are you sure? Type 'DELETE' to confirm: " confirm2
        if [[ "$confirm2" == "DELETE" ]]; then
            rm -rf "$SCRIPT_DIR/openclaw-home/credentials" 2>/dev/null || \
                warn "Could not fully remove credentials (permission issue)"
            rm -rf "$SCRIPT_DIR/openclaw-home/skills" 2>/dev/null || \
                warn "Could not fully remove skills (permission issue)"
            rm -rf "$SCRIPT_DIR/openclaw-home/workspace/memory" 2>/dev/null || \
                warn "Could not fully remove workspace/memory (permission issue)"
            info "Agent data deleted (workspace template files kept)"
        else
            warn "Kept agent data"
        fi
    else
        warn "Kept agent data"
    fi
fi

if [[ -d "$SCRIPT_DIR/logs" ]] && compgen -G "$SCRIPT_DIR/logs/*.log" &>/dev/null; then
    read -rp "Delete log files? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$SCRIPT_DIR/logs"/*.log
        rm -rf "$SCRIPT_DIR/logs/squid"
        info "Logs deleted (including Squid logs)"
    else
        warn "Kept logs"
    fi
fi

# --- Summary -----------------------------------------------------------------

step "Cleanup Complete"
echo ""
echo "  Removed: Docker containers, images, volumes"
echo "  Remaining files in: $SCRIPT_DIR/"
echo ""
echo "  To set up again: $SCRIPT_DIR/setup.sh"
echo ""
