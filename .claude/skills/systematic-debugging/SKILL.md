# Systematic Debugging

A 4-phase debugging methodology adapted for Docker/SSH/shell infrastructure in the Zupee Claw stack.

## Phase 1 — Reproduce

Confirm the problem exists and gather initial evidence.

- **Check container status**: Run `docker compose ps` and `docker compose logs` to see if services are running and healthy.
- **Check SSH connectivity**: Verify key permissions (must be `600`), check `known_hosts`, confirm `ForceCommand` is set in sshd config.
- **Check gateway logs**: Read `logs/gateway.log` and look for `DENIED` entries that correspond to the reported failure.
- **Check Claude logs**: Read `logs/claude.log` for execution errors, budget exhaustion, or turn limit hits.

## Phase 2 — Isolate

Determine which layer of the stack is responsible.

- **Docker layer**: Container won't start, healthcheck failing, resource limits exceeded (OOM kill).
- **SSH layer**: Connection refused, authentication failure, key permission error.
- **Gateway layer**: Command denied by allowlist, input validation rejection, rate limit hit (30/min).
- **Script layer**: Runtime error in a `bin/*.sh` script, missing dependency, bad input handling.

Test each layer independently, working from bottom to top:

1. Container health (`docker compose ps`)
2. SSH connectivity (`ssh -v` to the container)
3. Gateway routing (send a known-good command)
4. Script execution (run the script directly inside the container)

Also check:
- Is the user hitting the **30 commands/minute** rate limit?
- Is a container being **OOM-killed** due to resource limits?

## Phase 3 — Fix

Apply the minimal correct fix.

- Fix the issue at the **correct layer** (don't patch around a Docker problem in a shell script).
- **Maintain security invariants** — never disable validation, logging, or allowlist checks to work around a bug.
- Run **ShellCheck** on any modified shell scripts.
- Verify all **11 security layers** remain intact after the fix.

## Phase 4 — Verify

Confirm the fix works and nothing else broke.

- Re-run the full **reproduction steps** from Phase 1.
- Verify logs show the expected `ALLOWED`/`DENIED` entries.
- Run **ShellCheck** on all modified scripts: `shellcheck bin/*.sh setup.sh cleanup.sh`.
- If infrastructure changed (Docker, SSH config), run a full **setup.sh / cleanup.sh** cycle to confirm end-to-end behavior.
