# Docker Operations

Docker Compose topology and operations reference for the RCao Claw stack.

## Stack Overview

### Services

| Service     | Purpose                          |
|-------------|----------------------------------|
| `ollama`    | Local LLM inference engine       |
| `openclaw`  | SSH gateway + web UI + agent     |

### Networks

| Network       | Type     | Connected Services     | Purpose                        |
|---------------|----------|------------------------|--------------------------------|
| `isolated`    | internal | ollama, openclaw       | LLM inference traffic          |
| `host-access` | internal | openclaw only          | SSH to host for whitelisted commands |

### Volumes

- **`ollama-models`**: Named volume for downloaded LLM models (persistent across rebuilds).
- **Bind mounts for openclaw**: `openclaw-home/`, `bin/` (`:ro`), `config/` (`:ro`), `logs/` (`:rw`).

## Common Operations

### Start the stack

```bash
cd docker && docker compose up -d --build
```

### Stop the stack

```bash
docker compose down
```

### Rebuild without cache

```bash
docker compose build --no-cache
```

### View logs

```bash
docker compose logs -f            # all services
docker compose logs -f ollama     # ollama only
docker compose logs -f openclaw   # openclaw only
```

### Shell into the container

```bash
docker compose exec openclaw sh
```

### Ollama model management

```bash
docker compose exec ollama ollama list    # list installed models
docker compose exec ollama ollama pull <model>  # download a model
docker compose exec ollama ollama rm <model>    # remove a model
```

## Environment Configuration

All configuration is driven by the **`.env`** file in the project root. Key variables:

| Variable          | Purpose                              |
|-------------------|--------------------------------------|
| `OPENCLAW_VERSION`| Version tag for the openclaw image   |
| `WORKSPACE`       | Host path to the target repo         |
| `OLLAMA_MODEL`    | Default LLM model to use             |

- The `env_file` directive in `docker-compose.yml` loads `.env` into the openclaw container.
- `OLLAMA_HOST=http://ollama:11434` is set in the compose file for service discovery via Docker DNS.

## Health Checks

| Service  | Endpoint                                    | Interval |
|----------|---------------------------------------------|----------|
| ollama   | `curl -sf http://localhost:11434/api/tags`  | 10s      |
| openclaw | `curl -sf http://localhost:3000/health`     | 30s      |

## Troubleshooting

### Container won't start

1. Run `docker compose config` to validate the compose file.
2. Verify the `.env` file exists and contains all required variables.
3. Check the Docker daemon is running: `docker info`.
4. Look at container logs: `docker compose logs <service>`.

### SSH from container to host fails

1. Verify the SSH key exists at `/openclaw/.ssh/id_ed25519` inside the container.
2. Check key permissions are `600`: `docker compose exec openclaw ls -la /openclaw/.ssh/`.
3. Verify `known_hosts` contains the host entry.
4. Test connectivity: `docker compose exec openclaw ssh -v <host>`.

### Ollama not responding

1. Check the healthcheck status: `docker compose ps`.
2. Test the API directly: `docker compose exec ollama curl -sf http://localhost:11434/api/tags`.
3. List models to see if any are loaded: `docker compose exec ollama ollama list`.
4. Check resource usage — ollama may be OOM-killed if the 8G memory limit is exceeded.
