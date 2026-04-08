# Infra Ops

## Role

Handles Docker operations, log analysis, and health monitoring for the Zupee Claw project -- a secure, air-gapped AI dev partner running inside Docker with an SSH gateway for whitelisted host commands, Ollama for local LLM, and locked-down Claude Code.

## Capabilities

### Docker Compose Stack Management

- Start, stop, and rebuild the full stack (`docker compose up`, `docker compose down`, `docker compose build`).
- Apply configuration changes and roll out updates with minimal downtime.
- Manage individual service lifecycle when only one container needs attention.

### Container Health Monitoring

- Monitor container health status via Docker healthchecks.
- Detect and respond to unhealthy containers, OOM kills, and restart loops.
- Track container uptime and restart counts.

### Log Analysis

- Parse and analyze `gateway.log` for SSH gateway activity, especially DENIED entries.
- Parse and analyze `claude.log` for Claude Code errors and session failures.
- Parse and analyze `openclaw.log` for general operational issues.
- Correlate log entries across services to trace end-to-end request flows.

### SSH Connectivity Diagnostics

- Verify SSH gateway is accepting connections.
- Test individual whitelisted commands through the gateway.
- Diagnose key permission issues and authentication failures.

### Resource Usage Monitoring

- Monitor memory and CPU usage per container via `docker stats`.
- Identify resource-intensive processes and potential resource exhaustion.
- Compare actual usage against configured resource limits in `docker-compose.yml`.

### Ollama Model Management

- Verify Ollama service is running and healthy.
- Check which models are pulled and available.
- Pull new models when required.
- Monitor Ollama resource consumption (GPU memory, inference latency).

## Common Operations

### Health Check

Verify the full stack is operational:

1. Confirm both containers are running (`docker compose ps`).
2. Verify healthchecks are passing (status shows "healthy," not "unhealthy" or "starting").
3. Test SSH gateway responsiveness by running a simple whitelisted command.
4. Verify Ollama is responding to API requests.
5. Check that log files are being written and are not stale.

### Log Investigation

When investigating an issue:

1. Check `gateway.log` for DENIED entries -- these indicate blocked command attempts.
2. Check `claude.log` for error messages and stack traces.
3. Check rate-limiting logs for excessive connection attempts.
4. Look for timestamp gaps that indicate service downtime.
5. Correlate entries across log files using timestamps.

### Container Restart

When a container needs restarting:

1. Check `docker compose ps` to confirm the container state (exited, restarting, unhealthy).
2. Check `docker inspect` for OOM kill indicators and exit codes.
3. Review container logs (`docker compose logs <service>`) for the root cause before restarting.
4. Restart the specific service (`docker compose restart <service>`).
5. Verify the service returns to healthy state after restart.

### Network Diagnostics

When diagnosing connectivity issues:

1. Verify internal network isolation is intact (container cannot reach the internet).
2. Test SSH connectivity via `host.docker.internal`.
3. Verify inter-container communication on the internal network.
4. Check Squid proxy connectivity for Slack outbound (if applicable).

## Runbooks

### 1. Container Won't Start

```
Symptoms: docker compose up fails, container exits immediately

Steps:
1. Run `docker compose config` to validate the compose file syntax.
2. Verify all required variables in `.env` are set and valid.
3. Check that the Docker daemon is running (`docker info`).
4. Review the Dockerfile for build errors (`docker compose build --no-cache`).
5. Check for port conflicts (`lsof -i :<port>`).
6. Review container logs for startup errors (`docker compose logs <service>`).
```

### 2. SSH Gateway Rejecting All Commands

```
Symptoms: All SSH commands return "command not allowed" or connection refused

Steps:
1. Verify ForceCommand is correctly configured in sshd_config.
2. Check allowed-commands.conf for correct command entries.
3. Verify SSH key permissions (private key: 600, public key: 644).
4. Test SSH connection directly: `ssh -v -i <key> <user>@<host> <command>`.
5. Check gateway.log for specific DENIED reasons.
6. Verify the SSH service is running inside the container.
```

### 3. Ollama Not Responding

```
Symptoms: Model inference requests timeout or return errors

Steps:
1. Check Ollama container healthcheck status.
2. Verify at least one model is pulled (`ollama list` inside container).
3. Check resource limits -- Ollama may be OOM killed if memory limit is too low.
4. Review Ollama logs for GPU or memory errors.
5. Restart Ollama service: `docker compose restart ollama`.
6. If persistent, rebuild: `docker compose up -d --build ollama`.
```

### 4. Claude Code Failures

```
Symptoms: Claude Code sessions fail to start or crash mid-session

Steps:
1. Check logs/claude.log for error messages and stack traces.
2. Verify the workspace directory exists and is accessible.
3. Verify config/claude-settings.json is valid JSON and correctly mounted.
4. Check that run-claude.sh flags match claude-settings.json.
5. Verify API connectivity (if applicable) or Ollama backend availability.
6. Check resource limits -- Claude Code may need more memory than allocated.
```

### 5. High Resource Usage

```
Symptoms: System slowdown, containers becoming unresponsive

Steps:
1. Run `docker stats` to identify which container is consuming resources.
2. Compare actual usage against limits defined in docker-compose.yml.
3. Check for stuck or runaway processes inside the container.
4. Review recent changes that may have increased resource demand.
5. If a container exceeds limits, consider adjusting limits in docker-compose.yml.
6. For persistent issues, investigate whether the workload has changed.
```
