# Destructive Testing

Automated and manual testing procedures for validating setup.sh and cleanup.sh robustness.

## Automated Test Suite

Run the destructive test harness:

```bash
# Quick run (2 iterations, ~15 min)
./bin/destructive-test.sh --quick

# Full run (5 iterations, ~45 min)
./bin/destructive-test.sh

# Custom iterations
./bin/destructive-test.sh --iterations 10
```

### Test Cases (9 tests per iteration)

| Test | What it validates |
|------|------------------|
| Fresh setup | `./setup.sh --yes --role developer` from clean state |
| Idempotent re-run | Setup over existing setup doesn't break anything |
| Partial cleanup recovery | Delete `~/.openclaw`, re-run setup recovers |
| Container crash recovery | Kill containers, re-run setup restarts them |
| Role switch | developer → qa → developer personality swap |
| Missing .env | Delete .env, setup recreates from .env.example |
| Cleanup + re-setup | Full cleanup then fresh setup |
| Nuclear + fresh | Wipe everything, start from scratch |
| Permission corruption | chmod 000 ~/.openclaw, setup recovers |

### Flags

| Flag | Effect |
|------|--------|
| `--yes` / `-y` | Skip confirmation prompt |
| `--quick` | 2 iterations instead of 5 |
| `--iterations N` | Run N iterations |

## Manual Testing Procedures

### Test 1: Fresh Install (new employee laptop)

```bash
./cleanup.sh --yes
rm -rf ~/.openclaw
rm -f config/openclaw-docker-key config/openclaw-docker-key.pub
./setup.sh --role developer
# Verify: curl -sf http://localhost:3000/health
# Verify: docker ps | grep zupee
# Verify: ls ~/.openclaw/workspace/SOUL.md
```

### Test 2: Idempotent Re-run

```bash
./setup.sh --yes --role developer
./setup.sh --yes --role developer
# Second run should skip completed steps, not break anything
```

### Test 3: Role Switching

```bash
./setup.sh --yes --role qa
grep "QA" ~/.openclaw/workspace/SOUL.md  # Should find QA persona
./setup.sh --yes --role developer
grep "developer" ~/.openclaw/workspace/SOUL.md  # Should find developer
```

### Test 4: SSH Gateway Chain

```bash
# From inside the container:
docker exec zupee-claw ssh -i /home/openclaw/.ssh/id_ed25519 \
  ranjeet@host.docker.internal "service-status"

docker exec zupee-claw ssh -i /home/openclaw/.ssh/id_ed25519 \
  ranjeet@host.docker.internal "git-status"

docker exec zupee-claw ssh -i /home/openclaw/.ssh/id_ed25519 \
  ranjeet@host.docker.internal "run-claude say hello"
```

### Test 5: Claude Code Integration

```bash
# Simple response
docker exec zupee-claw ssh ... "run-claude say hello"

# Code review
docker exec zupee-claw ssh ... "run-claude review the changes in <file>"

# File creation (tests Write permission)
docker exec zupee-claw ssh ... "run-claude create a test file at /tmp/test.md with hello world"

# Blocked tools (should fail gracefully)
docker exec zupee-claw ssh ... "run-claude run curl google.com"
```

### Test 6: Proposal Workflow

```bash
# Agent creates proposal
docker exec zupee-claw ssh ... "run-claude review api-gateway/src/ and create a proposal PR if issues found"

# Verify: gh pr list --search "proposal:" --state open
# Verify: ls docs/proposed/
```

### Test 7: Model Change

```bash
sed -i '' 's/OLLAMA_MODEL=.*/OLLAMA_MODEL=qwen3:8b/' .env
./setup.sh --yes --role developer
# Verify model changed in OpenClaw config
```

## When to Run

- Before merging PRs that change `setup.sh`, `cleanup.sh`, or `docker-compose.yml`
- After upgrading OpenClaw version
- After changing Docker base image
- Before deploying to new employee laptops
- Monthly regression check

## Output

Test logs: `logs/destructive-test-YYYYMMDD-HHMMSS.log`

Expected result:
```
PASS:  72
FAIL:  0
SKIP:  2  (permission corruption needs sudo)
ALL TESTS PASSED
```
