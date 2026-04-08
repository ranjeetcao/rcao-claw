---
globs:
  - "docker/*"
---

# Docker Security Model

## Network Architecture

Two Docker networks provide strict isolation:

- **`isolated`** — `internal: true`. Connects `ollama` and `claw` services. Used for LLM inference traffic only.
- **`host-access`** — `internal: true`. Connects `claw` to the host via SSH. Used for whitelisted command execution.

Both networks have `internal: true` set, which means **no outbound internet access** from any container.

## Port Binding

- Web UI is bound to **`127.0.0.1:3000:3000`** only.
- Never bind to `0.0.0.0` — this would expose the service to the local network.

## Volume Mount Policy

- **Read-only (`:ro`)**: Scripts (`bin/`) and configuration files (`config/`). The agent cannot modify its own scripts.
- **Read-write (`:rw`)**: Logs directory and agent runtime data only.

## Resource Limits

| Service   | Memory | CPUs |
|-----------|--------|------|
| ollama    | 8G     | 4    |
| openclaw  | 2G     | 2    |

## Container Healthchecks

Healthchecks are **required** for both services. They ensure Docker can detect and report unhealthy containers.

## Image Pinning

Always use specific version tags for images (e.g., `ollama/ollama:0.6.2`). Never use `latest` or untagged images.

## NEVER Do the Following

- Add `privileged: true` to any service.
- Use `network_mode: host` on any service.
- Remove `internal: true` from either network.
- Mount `/` or `/etc` from the host.
- Add `cap_add` capabilities to any container.
