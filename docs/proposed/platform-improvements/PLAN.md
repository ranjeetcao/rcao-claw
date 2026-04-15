# Platform Improvements — Reliability, CI/CD, Docs, Testing

**Status:** PROPOSED
**Filed:** 2026-04-15
**Author:** Claude Opus (architecture session with Ranjeet)
**Scope:** CI/CD, documentation, testing, operations, monitoring

---

## 1. Problem Statement

The Zupee Claw platform has solid infrastructure and security layers (14-layer model, 72 passing destructive tests, 5-network Docker isolation). However, an audit revealed gaps across four areas that would block or confuse new employee onboarding, leave failures undetected, and allow regressions to ship:

- **No CI/CD pipeline** — shellcheck, secret scanning, and security config checks exist as Claude Code hooks but don't run on human commits or in CI
- **Stale documentation** — CLAUDE.md, README.md, and all docs/*.md reference the old `WORKSPACE_DIR`/`REPO` variables and `gemma4:e2b` model
- **Untested critical paths** — SSH gateway, post-setup smoke test, Slack agent with qwen3.5:9b, and proposal workflow have no automated tests
- **No monitoring or auto-recovery** — if Ollama crashes overnight or the model isn't pulled, the agent fails silently

---

## 2. Phases

### Phase 1 — Fix What Breaks Onboarding (P0)

_Target: before next employee onboards. Effort: 1-2 days._

#### 1.1 Documentation — Stale Variable References

Every reference to `WORKSPACE_DIR`, `REPO`, and `gemma4:e2b` across all docs must be updated.

| File | What's Wrong | Fix |
|------|-------------|-----|
| `README.md:34,59,75-77,140,150` | `$WORKSPACE_DIR/$REPO`, `gemma4:e2b` | Use `$WORKSPACE`, `qwen3.5:9b` |
| `CLAUDE.md:10,27,129` | `$WORKSPACE_DIR/$REPO`, "Default repo from `REPO`" | Use `$WORKSPACE`, remove `REPO` references |
| `docs/architecture.md:9,68,91,102,133,153,223,272-276,297,373` | Old vars, "4 networks" (now 5), "3 services" (now 5), missing searxng/valkey | Full rewrite of config table and service count |
| `docs/components.md:150,154,229,251,370,388` | Old vars, `gemma4:e2b` in JSON example, no searxng/valkey docs | Update vars, model, add new service entries |
| `docs/setup-and-operations.md:47-49,50-51,97,196,206,280,309-321,433,436` | Old vars, recommends `gemma4:e2b`, missing `SLACK_USER_TOKEN` | Update vars, model recommendation, Slack token docs |
| `docs/security-model.md:150,191` | Old vars, network matrix missing searxng and valkey rows | Update vars, add rows |
| `personality/shared/TOOLS.md:38` | Says "50 turns max" for run-claude | Should be "25 turns max" (matches `run-claude.sh`) |

#### 1.2 Missing Personality Files

QA and marketing roles reference `IDENTITY.md` in their `AGENTS.md` but the file doesn't exist in either directory. Developer role has a complete set; QA and marketing are skeletons.

| Role | Has | Missing |
|------|-----|---------|
| developer | SOUL.md, AGENTS.md, USER.md | (complete) |
| qa | SOUL.md, AGENTS.md | IDENTITY.md, USER.md, backlog workflow |
| marketing | SOUL.md, AGENTS.md | IDENTITY.md, USER.md, backlog workflow |

Fix: Create `personality/shared/IDENTITY.md` (shared across all roles) OR create role-specific IDENTITY.md files. Add backlog system section to QA and marketing AGENTS.md (or explicitly state they use a different workflow).

#### 1.3 Ollama Silent Failure on Missing Model

If the user skips the model pull during setup, the agent starts but every inference request fails silently.

Fix: Add a model readiness check in `docker/entrypoint.sh`:
```bash
# After Ollama is reachable, verify model exists
if ! curl -sf "$OLLAMA_HOST/api/tags" | grep -q "$OLLAMA_MODEL"; then
    echo "[entrypoint] FATAL: model $OLLAMA_MODEL not found"
    echo "[entrypoint] Run: ollama pull $OLLAMA_MODEL"
    exit 1
fi
```
The container's `restart: unless-stopped` policy surfaces this as an unhealthy state in `docker ps`.

#### 1.4 Ollama Native Auto-Restart

On macOS, Ollama is started with a background `&` that dies if the terminal closes or the process crashes. After laptop sleep/wake, Ollama is dead and the agent fails.

Fix: Add `config/com.zupee.claw.ollama.plist` LaunchAgent with `KeepAlive: true`. Install in `setup.sh` alongside the existing token-refresh LaunchAgent. Set `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_NUM_PARALLEL=1` to prevent OOM.

---

### Phase 2 — CI/CD Pipeline (P0-P1)

_Target: next week. Effort: 2-3 days._

#### 2.1 GitHub Actions — PR Validation (P0)

Create `.github/workflows/validate-pr.yml` running on every PR:

| Check | Tool | Rationale |
|-------|------|-----------|
| Shell lint | `shellcheck bin/*.sh setup.sh cleanup.sh tests/*.sh docker/entrypoint.sh` | Scripts are the core product; lint must be enforced |
| Secret scan | Extract patterns from `pre-commit-secrets.sh` into standalone script, or use `gitleaks` | Existing patterns cover Anthropic, Slack, AWS, GitHub tokens |
| Security config | Adapt `pre-commit-security-config.sh` — validate no `0.0.0.0` bindings, `internal: true` on networks, deny-list entries in claude-settings.json | Prevent accidental security regression |
| Compose validation | `docker compose -f docker/docker-compose.yml config --quiet` | Catch YAML errors and undefined variables |
| `.env.example` completeness | Cross-check variables in docker-compose.yml vs .env.example | Prevent silent empty-string substitution |
| Dockerfile lint | `hadolint docker/Dockerfile` | Catch unpinned apt-get, missing --no-install-recommends |

#### 2.2 Native Git Pre-Commit Hooks (P0)

The three Claude Code PreToolUse hooks (`pre-commit-secrets.sh`, `pre-commit-shellcheck.sh`, `pre-commit-security-config.sh`) only fire during AI-assisted commits. Human `git commit` bypasses them entirely.

Fix: Add a `.githooks/pre-commit` script that runs the same checks. `setup.sh` installs it via `git config core.hooksPath .githooks`. This closes the gap for human commits.

#### 2.3 Conventional Commit Enforcement (P2)

Add `commitlint` with `@commitlint/config-conventional` as a GitHub Actions step. Commit conventions are documented in CLAUDE.md but currently unenforced.

---

### Phase 3 — Test Coverage (P1)

_Target: this sprint. Effort: 3-4 days._

#### 3.1 Post-Setup Smoke Test

**File:** `tests/smoke-test.sh`

Run automatically at the end of `setup.sh` (or manually). Validates:

- [ ] Docker containers running and healthy (zupee-claw, zupee-squid, zupee-searxng, zupee-valkey)
- [ ] Gateway HTTP health: `curl -sf http://localhost:3000/health`
- [ ] Ollama reachable and model loaded: `curl http://localhost:11434/api/tags | grep $OLLAMA_MODEL`
- [ ] SSH ForceCommand works: `ssh -i config/openclaw-docker-key $USER@localhost service-status`
- [ ] Personality files present in `~/.openclaw/workspace/` (SOUL.md, AGENTS.md, TOOLS.md, IDENTITY.md)
- [ ] LaunchAgents loaded (token-refresh, ollama if native)
- [ ] Credentials cache exists and is fresh
- [ ] Claude Code settings installed

Fully automatable. Exit 0/1.

#### 3.2 SSH Gateway Test Suite

**File:** `tests/test-ssh-gateway.sh`

Test `ssh-gateway.sh` directly by setting `SSH_ORIGINAL_COMMAND` env var (no real SSH needed).

**Allow cases:** `service-status`, `git-status`, `git-status my-repo`, `run-tests`, `run-claude say hello`

**Deny cases:**
- Empty command (interactive shell attempt)
- `../etc/passwd` (path traversal)
- `/bin/bash` (absolute path)
- `service-status; rm -rf ~` (semicolon injection)
- `git-status $(whoami)` (command substitution)
- `notinlist` (not in allowlist)
- Rate limit: 31 rapid-fire calls should trigger the 30/min limit

**Log verification:** Assert `gateway.log` contains DENIED for each blocked call.

#### 3.3 Agent Tool-Use Test

**File:** `tests/test-agent-tools.sh`

Test qwen3.5:9b via direct Ollama API with the developer AGENTS.md as system prompt:

- Given "check git status" task, response should contain tool invocation (exec/read), not a refusal
- Given "list files in /workspace" task, response should suggest `ls` or `find`, not guess
- Given "how many blog posts" with directory listing result, should plan to explore subdirectories
- Response time under 300s (matches `agents.defaults.timeoutSeconds`)

#### 3.4 CI-Eligible Tests

| Test | CI? | Reason |
|------|-----|--------|
| `tests/smoke-test.sh` | Partial | Container health yes, SSH/Ollama no |
| `tests/test-ssh-gateway.sh` | Yes | Pure bash, no Docker needed |
| `tests/test-search.sh --quick` | Yes (with Docker) | Health + basic search on Linux runner |
| `tests/destructive-test.sh` | No | Mutates host, needs sudo |
| `tests/quality-tests.sh` | No | Needs Ollama + GPU hardware |
| `tests/benchmark-models.sh` | No | Hardware-specific |

---

### Phase 4 — Operations (P1-P2)

_Target: next two weeks. Effort: 2-3 days._

#### 4.1 Monitoring via service-status.sh

Extend `bin/service-status.sh` to check:

- Docker container health states (all 4 containers)
- Ollama process alive and model loaded (native mode)
- Token cache freshness (`~/.claude/.credentials-cache` mtime < 20 min)
- Disk usage of `logs/` directory
- Available system memory vs model requirement

This script is already in the SSH gateway allowlist — the agent can self-report its own health via Slack.

#### 4.2 Log Rotation

Add `config/com.zupee.claw.logrotate.plist` LaunchAgent:

- Runs daily
- Caps `logs/*.log` at 10 MB, keeps 3 rotations
- Handles `logs/squid/access.log` and `logs/squid/cache.log`
- Simple `tail -c 10M` + `mv` approach (no logrotate dependency)

#### 4.3 Update Workflow

Add `bin/update.sh` (host-side only, not in SSH allowlist):

```
1. git pull --rebase
2. Compare .env OPENCLAW_VERSION with running container label
3. docker compose build (if version changed)
4. ollama pull $OLLAMA_MODEL (if model changed)
5. docker compose up -d
6. Run smoke-test.sh
```

`service-status.sh` should emit "Update available: run ./update.sh" when the running version differs from `.env`.

#### 4.4 Token Refresh Failure Detection (P2)

Modify the token-refresh LaunchAgent to touch a sentinel file `~/.claude/.credentials-cache-ok` on success. `service-status.sh` checks the mtime — stale > 20 min = warn. Closes the silent failure loop where Keychain access is revoked after an OS update.

---

## 3. Task Breakdown

| ID | Phase | Task | Priority | Effort | Depends On |
|----|-------|------|----------|--------|------------|
| T1 | 1 | Update all docs: WORKSPACE_DIR/REPO to WORKSPACE | P0 | M | — |
| T2 | 1 | Update all docs: gemma4:e2b to qwen3.5:9b | P0 | S | — |
| T3 | 1 | Update docs: add searxng + valkey to architecture, components, security-model | P0 | M | — |
| T4 | 1 | Create missing personality files (QA + marketing IDENTITY.md) | P0 | S | — |
| T5 | 1 | Fix TOOLS.md: 50 turns -> 25 turns | P0 | S | — |
| T6 | 1 | Add model readiness check in entrypoint.sh | P0 | S | — |
| T7 | 1 | Add Ollama LaunchAgent for native auto-restart | P0 | S | — |
| T8 | 2 | Create .github/workflows/validate-pr.yml | P0 | M | — |
| T9 | 2 | Wire pre-commit hooks for human git commits | P0 | S | — |
| T10 | 3 | Create tests/smoke-test.sh | P1 | M | T6, T7 |
| T11 | 3 | Create tests/test-ssh-gateway.sh | P1 | M | — |
| T12 | 3 | Create tests/test-agent-tools.sh | P1 | M | — |
| T13 | 3 | Add smoke-test.sh to CI (container health subset) | P1 | S | T8, T10 |
| T14 | 3 | Add test-ssh-gateway.sh to CI | P1 | S | T8, T11 |
| T15 | 4 | Extend service-status.sh with full health checks | P1 | S | — |
| T16 | 4 | Add log rotation LaunchAgent | P1 | S | — |
| T17 | 4 | Create bin/update.sh | P1 | M | T10 |
| T18 | 4 | Add conventional commit enforcement in CI | P2 | S | T8 |
| T19 | 4 | Token refresh failure detection | P2 | S | T15 |

---

## 4. Success Criteria

- [ ] New employee can run `./setup.sh --role developer` on a fresh M4 Pro MacBook and have a working agent in under 10 minutes, with no stale documentation confusing them
- [ ] Every PR is automatically validated for shell lint, secrets, security config, and compose validity
- [ ] Human commits are checked by the same hooks that protect AI commits
- [ ] If Ollama crashes or the model is missing, the failure is visible (not silent)
- [ ] `service-status` gives a complete health picture (containers, model, tokens, disk)
- [ ] SSH gateway has automated tests proving all 14 deny scenarios are blocked
- [ ] Post-setup smoke test runs automatically and catches 90% of setup failures

---

## 5. Out of Scope

- Full Prometheus/Grafana monitoring (these are laptops, not servers)
- Slack workspace provisioning automation (one-time manual setup per developer)
- Agent self-update via SSH gateway (security surface area not justified yet)
- Performance regression testing in CI (hardware-dependent, local only)

---

## 6. Risks

| Risk | Mitigation |
|------|-----------|
| CI pipeline adds friction to small fixes | Keep it fast (<2 min). Only block on P0 checks; P2 checks are advisory |
| Ollama LaunchAgent conflicts with manual `ollama serve` | setup.sh should detect if Ollama is already running and skip LaunchAgent install |
| Docs drift again after this cleanup | CI check: validate no `WORKSPACE_DIR` or `REPO=` patterns in docs/*.md |
| update.sh breaks mid-update | Script must be idempotent. Smoke test at the end validates success |
