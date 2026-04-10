# Testing Runbook

Destructive testing procedures for validating setup.sh and cleanup.sh robustness.

## Quick Start

```bash
# Run automated destructive tests (2 iterations)
./bin/destructive-test.sh --quick

# Full test suite (5 iterations, ~30 min)
./bin/destructive-test.sh

# Custom iteration count
./bin/destructive-test.sh --iterations 10
```

## What the Test Suite Covers

| Test | Scenario | Validates |
|------|----------|-----------|
| Fresh setup | Nuclear cleanup then `setup.sh --yes --role developer` | Clean install from nothing works |
| Idempotent re-run | Run setup over existing working setup | Re-running doesn't break anything |
| Partial cleanup recovery | Delete `~/.openclaw`, then re-run setup | Recovers from missing runtime state |
| Container crash recovery | `docker kill` containers, then re-run setup | Recovers from crashed containers |
| Role switch | Setup as developer, switch to qa, switch back | Personality files update correctly |
| Missing .env | Delete `.env`, then re-run setup | Auto-creates from `.env.example` |
| Cleanup + re-setup | Full `cleanup.sh --yes`, then re-setup | Clean slate recovery works |
| Nuclear + fresh | Wipe everything (containers, images, ~/.openclaw, SSH keys), fresh setup | Worst-case recovery |
| Permission corruption | `chmod 000 ~/.openclaw`, then re-setup | Recovers from broken permissions |

## Manual Testing Procedures

### Test 1: Fresh Install (simulates new employee laptop)

```bash
# 1. Wipe everything
./cleanup.sh --yes
sudo rm -rf ~/.openclaw
rm -f config/openclaw-docker-key config/openclaw-docker-key.pub

# 2. Fresh setup
./setup.sh --role developer

# 3. Verify
curl -sf http://localhost:3000/health    # Should return {"ok":true}
docker ps | grep zupee                   # zupee-claw and zupee-squid running
ls ~/.openclaw/workspace/SOUL.md         # Personality files present
ollama ps                                # Model loaded (native mode)
```

### Test 2: Idempotent Re-run

```bash
# Run setup twice in a row — second run should skip completed steps
./setup.sh --yes --role developer
./setup.sh --yes --role developer

# Verify nothing broke
curl -sf http://localhost:3000/health
```

### Test 3: Partial Failure Recovery

```bash
# Simulate: setup crashed midway, ~/.openclaw exists but is incomplete
rm -rf ~/.openclaw/workspace
./setup.sh --yes --role developer
# Should recreate workspace and copy personality files

# Simulate: Docker containers died
docker kill zupee-claw zupee-squid
./setup.sh --yes --role developer
# Should restart containers

# Simulate: .env was deleted
mv .env .env.backup
./setup.sh --yes --role developer
# Should auto-create .env from .env.example
mv .env.backup .env  # restore your config
```

### Test 4: Role Switching

```bash
# Switch roles
./setup.sh --yes --role qa
grep "QA" ~/.openclaw/workspace/SOUL.md      # Should find QA persona

./setup.sh --yes --role marketing
grep "marketing" ~/.openclaw/workspace/SOUL.md  # Should find marketing persona

./setup.sh --yes --role developer
grep "developer" ~/.openclaw/workspace/SOUL.md  # Should find developer persona
```

### Test 5: Cleanup Completeness

```bash
# Full cleanup
./cleanup.sh --yes

# Verify everything is gone
docker ps | grep zupee       # No containers
ls ~/.openclaw 2>/dev/null   # Directory removed
ls config/openclaw-docker-key 2>/dev/null  # SSH key removed

# Re-setup from clean state
./setup.sh --role developer
```

### Test 6: Permission Corruption Recovery

```bash
# Corrupt permissions
chmod 000 ~/.openclaw

# Setup should recover (may need sudo)
./setup.sh --yes --role developer

# Verify
curl -sf http://localhost:3000/health
```

### Test 7: Docker Image Rebuild

```bash
# Force rebuild (simulates Dockerfile changes)
cd docker && docker compose build --no-cache && cd ..
./setup.sh --yes --role developer

# Verify new image is used
docker inspect zupee-claw --format='{{.Image}}' | head -1
```

### Test 8: Model Change

```bash
# Change model in .env
sed -i '' 's/OLLAMA_MODEL=.*/OLLAMA_MODEL=qwen3:8b/' .env
sed -i '' 's/OLLAMA_MODEL_MEM=.*/OLLAMA_MODEL_MEM=8/' .env

# Re-run setup (should configure new model)
./setup.sh --yes --role developer

# Verify
docker exec zupee-claw cat /home/openclaw/.openclaw/openclaw.json | jq '.agents.defaults.model.primary'
# Should show "ollama/qwen3:8b"

# Revert
sed -i '' 's/OLLAMA_MODEL=.*/OLLAMA_MODEL=qwen3.5:9b/' .env
sed -i '' 's/OLLAMA_MODEL_MEM=.*/OLLAMA_MODEL_MEM=10/' .env
```

## Non-Interactive Flags

| Script | Flag | Effect |
|--------|------|--------|
| `setup.sh` | `--yes` / `-y` | Auto-confirm all prompts (skips sudo steps if password required) |
| `setup.sh` | `--role <name>` | Select role without prompt |
| `cleanup.sh` | `--yes` / `-y` | Auto-confirm all prompts (including "Type DELETE") |
| `destructive-test.sh` | `--quick` | Run 2 iterations instead of 5 |
| `destructive-test.sh` | `--iterations N` | Run N iterations |

## Test Output

Test logs are written to `logs/destructive-test-YYYYMMDD-HHMMSS.log`.

Example output:
```
=== FINAL RESULTS ===

  Iterations:  5
  Duration:    45 minutes
  PASS:  180
  FAIL:  0
  SKIP:  5
  Total: 185

  ALL TESTS PASSED
```

## When to Run These Tests

- **Before merging** any PR that changes `setup.sh`, `cleanup.sh`, or `docker-compose.yml`
- **After upgrading** OpenClaw version (`OPENCLAW_VERSION` in `.env`)
- **After changing** Docker base image or Dockerfile
- **After changing** the personality/ directory structure
- **Before deploying** to a new batch of employee laptops
- **Monthly** as a regression check

## Known Limitations

- Tests that require `sudo` (user creation, SSH config) are skipped in `--yes` mode if sudo needs a password. Run interactively to test those paths.
- Model pull tests depend on network connectivity and can be slow (~60s per model).
- Docker Desktop memory limits can cause OOM in Docker mode -- native mode avoids this.
- The test suite leaves the system in a working state (final restore step).
