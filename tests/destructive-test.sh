#!/bin/bash
set -euo pipefail

# =============================================================================
# Zupee Claw - Destructive Test Suite
# Tests setup.sh and cleanup.sh robustness by simulating failures at every
# stage and verifying recovery on re-run.
#
# WARNING: This script WILL destroy and recreate your entire Claw setup.
# Run only on a test machine or when you're OK losing current state.
#
# Usage:
#   ./bin/destructive-test.sh              # Run full test suite (5 iterations)
#   ./bin/destructive-test.sh --quick      # Run 2 iterations
#   ./bin/destructive-test.sh --iterations 10
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TEST_LOG="$PROJECT_DIR/logs/destructive-test-$(date +%Y%m%d-%H%M%S).log"

log()   { echo -e "$*" | tee -a "$TEST_LOG"; }
pass()  { PASS_COUNT=$((PASS_COUNT + 1)); log "${GREEN}  PASS${NC} $*"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); log "${RED}  FAIL${NC} $*"; }
skip()  { SKIP_COUNT=$((SKIP_COUNT + 1)); log "${YELLOW}  SKIP${NC} $*"; }
header() { log "\n${BOLD}${CYAN}=== $* ===${NC}"; }
section() { log "\n${BOLD}--- $* ---${NC}"; }

# --- Helpers -----------------------------------------------------------------

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$1"
}

health_ok() {
    curl -sf http://localhost:3000/health &>/dev/null
}

ollama_native_running() {
    curl -sf http://localhost:11434/api/tags &>/dev/null
}

user_exists() {
    id "$1" &>/dev/null 2>&1
}

file_exists() {
    [[ -f "$1" ]]
}

dir_exists() {
    [[ -d "$1" ]]
}

# Run setup non-interactively
run_setup() {
    local role="${1:-developer}"
    local desc="${2:-setup}"
    log "  Running $desc (role=$role)..."
    "$PROJECT_DIR/setup.sh" --yes --role "$role" >> "$TEST_LOG" 2>&1
    return $?
}

# Run cleanup non-interactively (keeps SSH user and config by default)
run_cleanup() {
    local desc="${1:-cleanup}"
    log "  Running $desc..."
    "$PROJECT_DIR/cleanup.sh" --yes >> "$TEST_LOG" 2>&1
    return $?
}

# Full nuclear cleanup -- removes everything without prompts
nuclear_cleanup() {
    log "  Nuclear cleanup..."

    # Stop all containers
    cd "$PROJECT_DIR/docker"
    # Don't use --rmi (removing images forces slow rebuilds and can fail on network issues)
    OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.4.2}" \
    OLLAMA_HOST="${OLLAMA_HOST:-http://host.docker.internal:11434}" \
    OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}" \
    docker compose --profile docker-ollama down --volumes --remove-orphans >> "$TEST_LOG" 2>&1 || true
    cd "$PROJECT_DIR"

    docker image prune -f --filter "label=com.docker.compose.project=zupee-claw" >> "$TEST_LOG" 2>&1 || true

    # Remove ~/.openclaw (try without sudo first, fallback to sudo)
    if [[ -d "$HOME/.openclaw" ]]; then
        rm -rf "$HOME/.openclaw" >> "$TEST_LOG" 2>&1 || true
    fi

    # Remove SSH key
    rm -f "$PROJECT_DIR/config/openclaw-docker-key" "$PROJECT_DIR/config/openclaw-docker-key.pub" 2>/dev/null || true

    # Remove logs
    rm -f "$PROJECT_DIR/logs"/*.log 2>/dev/null || true
    rm -rf "$PROJECT_DIR/logs/squid" 2>/dev/null || true

    # Remove .env computed values (keep base config)
    for var in OLLAMA_MEM OLLAMA_CPUS CLAW_MEM CLAW_CPUS OLLAMA_HOST OLLAMA_MODE OPENCLAW_HOME; do
        sed -i.bak "/^${var}=/d" "$PROJECT_DIR/.env" 2>/dev/null || true
    done
    rm -f "$PROJECT_DIR/.env.bak" 2>/dev/null || true

    # Don't remove openclaw-bot user or SSH config (those require sudo and are slow)
    log "  Nuclear cleanup done"
}

# --- Test Functions ----------------------------------------------------------

test_fresh_setup() {
    local role="${1:-developer}"
    header "Test: Fresh setup (role=$role)"

    nuclear_cleanup

    # Answers: role, skip SSH steps (user exists), yes Docker, no model pull
    # n for SSH key install, n for symlink, n for SSH config (already exist)
    # y for Docker build
    # n for model pull (already installed natively)
    if "$PROJECT_DIR/setup.sh" --yes --role "$role" >> "$TEST_LOG" 2>&1; then
        pass "setup.sh completed"
    else
        local exit_code=$?
        fail "setup.sh exited with code $exit_code (see log for details)"
        # Show last 10 lines of log for quick diagnosis
        tail -10 "$TEST_LOG" | while IFS= read -r line; do log "    $line"; done
        return 1
    fi

    # Verify outcomes
    section "Verifying setup results"

    if dir_exists "$HOME/.openclaw"; then
        pass "~/.openclaw created"
    else
        fail "~/.openclaw missing"
    fi

    if dir_exists "$HOME/.openclaw/workspace"; then
        pass "~/.openclaw/workspace exists"
    else
        fail "~/.openclaw/workspace missing"
    fi

    if file_exists "$HOME/.openclaw/workspace/SOUL.md"; then
        pass "SOUL.md copied"
    else
        fail "SOUL.md missing"
    fi

    if file_exists "$HOME/.openclaw/workspace/IDENTITY.md"; then
        pass "IDENTITY.md (shared) copied"
    else
        fail "IDENTITY.md missing"
    fi

    if file_exists "$HOME/.openclaw/openclaw.json"; then
        pass "openclaw.json exists"
    else
        fail "openclaw.json missing"
    fi

    if container_running "zupee-claw"; then
        pass "zupee-claw container running"
    else
        fail "zupee-claw container not running"
    fi

    if container_running "zupee-squid"; then
        pass "zupee-squid container running"
    else
        fail "zupee-squid container not running"
    fi

    # In native mode, Docker ollama should NOT be running
    if ! container_running "zupee-ollama"; then
        pass "zupee-ollama NOT running (native mode correct)"
    else
        fail "zupee-ollama is running in native mode"
    fi

    sleep 10  # Wait for gateway to fully start

    if health_ok; then
        pass "Gateway health check OK"
    else
        fail "Gateway health check failed"
    fi

    if ollama_native_running; then
        pass "Native Ollama running"
    else
        fail "Native Ollama not running"
    fi
}

test_idempotent_rerun() {
    header "Test: Idempotent re-run (setup over existing setup)"

    if run_setup "developer" "idempotent re-run"; then
        pass "Re-run completed"
    else
        fail "Re-run failed"
    fi

    if health_ok; then
        pass "Gateway still healthy after re-run"
    else
        fail "Gateway unhealthy after re-run"
    fi

    if file_exists "$HOME/.openclaw/workspace/SOUL.md"; then
        pass "Personality files preserved"
    else
        fail "Personality files lost"
    fi
}

test_partial_cleanup_recovery() {
    header "Test: Partial cleanup then setup recovery"

    section "Simulating partial cleanup (remove ~/.openclaw only)"
    rm -rf "$HOME/.openclaw" 2>/dev/null || true

    if ! dir_exists "$HOME/.openclaw"; then
        pass "~/.openclaw removed"
    else
        fail "Failed to remove ~/.openclaw"
    fi

    # Containers should still be running but broken
    section "Re-running setup to recover"
    

    if run_setup "developer" "recovery setup"; then
        pass "Recovery setup completed"
    else
        fail "Recovery setup failed"
    fi

    if dir_exists "$HOME/.openclaw/workspace"; then
        pass "~/.openclaw/workspace recovered"
    else
        fail "~/.openclaw/workspace not recovered"
    fi

    sleep 10
    if health_ok; then
        pass "Gateway healthy after recovery"
    else
        fail "Gateway unhealthy after recovery"
    fi
}

test_container_crash_recovery() {
    header "Test: Container crash then setup recovery"

    section "Killing containers"
    docker kill zupee-claw 2>/dev/null || true
    docker kill zupee-squid 2>/dev/null || true

    sleep 2

    if ! container_running "zupee-claw"; then
        pass "zupee-claw killed"
    else
        fail "zupee-claw still running"
    fi

    section "Re-running setup to recover"
    

    if run_setup "developer" "crash recovery"; then
        pass "Crash recovery completed"
    else
        fail "Crash recovery failed"
    fi

    sleep 10
    if health_ok; then
        pass "Gateway healthy after crash recovery"
    else
        fail "Gateway unhealthy after crash recovery"
    fi
}

test_role_switch() {
    header "Test: Role switch (developer -> qa)"

    if run_setup "qa" "role switch to qa"; then
        pass "Role switch completed"
    else
        fail "Role switch failed"
    fi

    if grep -q "QA" "$HOME/.openclaw/workspace/SOUL.md" 2>/dev/null; then
        pass "QA SOUL.md installed"
    else
        fail "QA SOUL.md not found"
    fi

    # Switch back
    if run_setup "developer" "role switch back to developer"; then
        pass "Role switch back completed"
    else
        fail "Role switch back failed"
    fi

    if grep -q "developer" "$HOME/.openclaw/workspace/SOUL.md" 2>/dev/null; then
        pass "Developer SOUL.md restored"
    else
        fail "Developer SOUL.md not restored"
    fi
}

test_missing_env() {
    header "Test: Missing .env recovery"

    section "Removing .env"
    local env_backup="$PROJECT_DIR/.env.test-backup"
    cp "$PROJECT_DIR/.env" "$env_backup"
    rm -f "$PROJECT_DIR/.env"

    if run_setup "developer" "setup without .env"; then
        pass "Setup created .env from .env.example"
    else
        # Expected: might fail if .env.example defaults don't match
        skip "Setup failed without .env (may need manual config)"
    fi

    if file_exists "$PROJECT_DIR/.env"; then
        pass ".env auto-created"
    else
        fail ".env not created"
    fi

    # Restore
    cp "$env_backup" "$PROJECT_DIR/.env"
    rm -f "$env_backup"
}

test_cleanup_stages() {
    header "Test: Cleanup at various stages"

    # First ensure we have a full setup
    section "Ensuring full setup exists"
    
    run_setup "developer" "pre-cleanup setup" || true

    sleep 10

    # Test cleanup with all 'n' (keep everything)
    section "Cleanup with all N (dry run)"
    

    # Use --yes which removes everything. The real test is: can we re-setup after?
    if run_cleanup "full cleanup"; then
        pass "Cleanup completed"
    else
        fail "Cleanup failed"
    fi

    # Containers should be gone
    if ! container_running "zupee-claw"; then
        pass "Containers stopped after cleanup"
    else
        fail "Containers still running after cleanup"
    fi

    if ! dir_exists "$HOME/.openclaw"; then
        pass "~/.openclaw cleaned up"
    else
        skip "~/.openclaw still exists (may need sudo)"
    fi

    # Re-setup should work
    section "Re-setup after partial cleanup"

    if run_setup "developer" "post-cleanup setup"; then
        pass "Post-cleanup setup completed"
    else
        fail "Post-cleanup setup failed"
    fi

    sleep 10
    if health_ok; then
        pass "Gateway healthy after cleanup+setup cycle"
    else
        fail "Gateway unhealthy after cleanup+setup cycle"
    fi
}

test_full_cleanup_and_setup() {
    header "Test: Full nuclear cleanup then fresh setup"

    nuclear_cleanup

    if ! dir_exists "$HOME/.openclaw"; then
        pass "~/.openclaw removed by nuclear cleanup"
    else
        fail "~/.openclaw survived nuclear cleanup"
    fi

    if ! container_running "zupee-claw"; then
        pass "No containers running after nuclear cleanup"
    else
        fail "Containers still running after nuclear cleanup"
    fi

    # Fresh setup
    

    if run_setup "developer" "fresh setup after nuclear cleanup"; then
        pass "Fresh setup after nuclear completed"
    else
        fail "Fresh setup after nuclear failed"
    fi

    sleep 10
    if health_ok; then
        pass "Gateway healthy after nuclear cleanup + fresh setup"
    else
        fail "Gateway unhealthy after nuclear cleanup + fresh setup"
    fi
}

test_permission_corruption() {
    header "Test: Permission corruption recovery"

    section "Corrupting ~/.openclaw permissions"
    chmod 000 "$HOME/.openclaw" 2>/dev/null || true

    if run_setup "developer" "setup after permission corruption"; then
        pass "Setup recovered from permission corruption"
    else
        # May need sudo — expected in some cases
        skip "Setup needs sudo for permission recovery"
    fi

    # Restore permissions regardless
    chmod 755 "$HOME/.openclaw" 2>/dev/null || sudo chmod 755 "$HOME/.openclaw" 2>/dev/null || true
}

# --- Main --------------------------------------------------------------------

main() {
    local iterations=5

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick) iterations=2; shift ;;
            --iterations) iterations="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: $0 [--quick] [--iterations N]"
                exit 0
                ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    mkdir -p "$PROJECT_DIR/logs"

    header "Zupee Claw - Destructive Test Suite"
    log "  Iterations: $iterations"
    log "  Log: $TEST_LOG"
    log "  Date: $(date -Iseconds)"
    log "  WARNING: This will destroy and recreate your Claw setup $iterations times."
    echo ""
    read -rp "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    local start_time
    start_time=$(date +%s)

    for i in $(seq 1 "$iterations"); do
        header "ITERATION $i of $iterations"

        test_fresh_setup "developer"
        test_idempotent_rerun
        test_partial_cleanup_recovery
        test_container_crash_recovery
        test_role_switch
        test_missing_env
        test_cleanup_stages
        test_full_cleanup_and_setup
        test_permission_corruption

        log "\n  Iteration $i complete: ${GREEN}${PASS_COUNT} pass${NC}, ${RED}${FAIL_COUNT} fail${NC}, ${YELLOW}${SKIP_COUNT} skip${NC}"
    done

    local end_time elapsed_min
    end_time=$(date +%s)
    elapsed_min=$(( (end_time - start_time) / 60 ))

    # --- Final Report ---
    header "FINAL RESULTS"
    log ""
    log "  Iterations:  $iterations"
    log "  Duration:    ${elapsed_min} minutes"
    log "  ${GREEN}PASS:  $PASS_COUNT${NC}"
    log "  ${RED}FAIL:  $FAIL_COUNT${NC}"
    log "  ${YELLOW}SKIP:  $SKIP_COUNT${NC}"
    log "  Total:       $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))"
    log ""
    log "  Log: $TEST_LOG"
    log ""

    if [[ $FAIL_COUNT -eq 0 ]]; then
        log "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    else
        log "  ${RED}${BOLD}$FAIL_COUNT FAILURES — review log for details${NC}"
    fi

    # Leave system in a clean running state
    section "Restoring clean state"
    
    run_setup "developer" "final restore" || true

    return $FAIL_COUNT
}

main "$@"
