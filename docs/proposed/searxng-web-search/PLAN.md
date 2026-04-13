# SearXNG Web Search Integration

**Status:** PROPOSED  
**Filed:** 2026-04-12  
**Author:** Claude Opus (architecture session with Ranjeet)  
**Scope:** Docker infrastructure, Squid ACL, OpenClaw config

---

## 1. Problem Statement

The Claw developer agent has no web search capability. When developers ask questions that require current documentation, API references, or Stack Overflow solutions, the agent cannot help. The `WebSearch` and `WebFetch` tools are blocked in `run-claude.sh` and the container has no direct internet access.

**Why now:** Developers frequently need to look up framework docs, error messages, library APIs, and best practices. Without web search, the agent is limited to what's in the local codebase.

---

## 2. Proposed Solution

Deploy **SearXNG** as a self-hosted meta-search engine inside the Docker stack. SearXNG aggregates results from multiple search engines (Google, DuckDuckGo, GitHub, StackOverflow) without requiring API keys. It integrates natively with OpenClaw's `web_search` tool via a JSON API.

### Why SearXNG

| Criteria | SearXNG | Brave API | Google API |
|----------|---------|-----------|------------|
| Cost | Free | Free tier + paid | Paid |
| API keys | None needed | Required | Required |
| Privacy | Self-hosted, no tracking | 3rd party | 3rd party |
| Air-gap capable | Yes | No | No |
| Setup complexity | Docker service | API key only | API key + billing |
| Fits Claw security model | Yes (Squid proxy) | Partially | Partially |

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Docker Compose Stack                                     │
│                                                         │
│  ┌──────────────┐    web_search()    ┌──────────────┐  │
│  │  Claw Agent  │ ──────────────────→│   SearXNG    │  │
│  │  (openclaw)  │    squid-internal  │   :8080      │  │
│  └──────────────┘                    └──────┬───────┘  │
│                                             │           │
│                                      squid-egress      │
│                                             │           │
│                                      ┌──────▼───────┐  │
│  ┌──────────────┐                    │  Squid Proxy │  │
│  │   Valkey     │ ←── cache ────────→│  :3128       │  │
│  │   (Redis)    │    squid-internal  └──────┬───────┘  │
│  └──────────────┘                           │           │
│                                      squid-egress      │
└─────────────────────────────────────────────┼───────────┘
                                              │
                                    ┌─────────▼──────────┐
                                    │  Search Engines     │
                                    │  google.com         │
                                    │  duckduckgo.com     │
                                    │  api.github.com     │
                                    │  stackoverflow.com  │
                                    │  arxiv.org          │
                                    └────────────────────┘
```

### Network Placement

| Service | Networks | Internet |
|---------|----------|----------|
| searxng | squid-internal, squid-egress | Via Squid proxy only |
| valkey | squid-internal | None |
| openclaw | squid-internal (existing) | Via Squid proxy only |

### Data Flow

1. Agent calls `web_search({ query: "fastify rate limiting" })`
2. OpenClaw routes to SearXNG at `http://searxng:8080/search?q=...&format=json`
3. SearXNG queries upstream engines through Squid proxy
4. Squid allows only whitelisted search engine domains
5. Results cached in Valkey (15 min TTL)
6. Structured JSON returned to agent (titles, URLs, snippets)

---

## 4. Implementation Tasks

| # | Task | Files | Risk |
|---|------|-------|------|
| SXG-01 | Add SearXNG + Valkey services to docker-compose.yml | `docker/docker-compose.yml` | Low |
| SXG-02 | Create SearXNG settings with developer-focused engines | `config/searxng-settings.yml` | Low |
| SXG-03 | Create SearXNG limiter config (disable bot detection) | `config/searxng-limiter.toml` | Low |
| SXG-04 | Update Squid ACL to allow search engine domains | `config/squid.conf` | Medium |
| SXG-05 | Configure OpenClaw to use SearXNG as web_search provider | `setup.sh` | Low |
| SXG-06 | Add SEARXNG_SECRET to .env.example | `.env.example` | Low |
| SXG-07 | Update CLAUDE.md and docs with web search architecture | `CLAUDE.md`, `docs/` | Low |
| SXG-08 | Test web_search from Slack and Web UI | Manual test | Low |

**Order:** SXG-01 → SXG-02 → SXG-03 → SXG-04 → SXG-05 → SXG-06 → SXG-07 → SXG-08

---

## 5. Detailed Changes

### SXG-01: Docker Compose — Add SearXNG + Valkey

```yaml
  valkey:
    image: valkey/valkey:8-alpine
    container_name: zupee-valkey
    networks:
      - squid-internal
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: "0.25"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 30s
      timeout: 3s
      retries: 3

  searxng:
    image: searxng/searxng:latest
    container_name: zupee-searxng
    environment:
      - SEARXNG_SECRET=${SEARXNG_SECRET:-change-me-in-production}
      - SEARXNG_VALKEY_URL=redis://valkey:6379
      - http_proxy=http://squid:3128
      - https_proxy=http://squid:3128
      - no_proxy=valkey,localhost,127.0.0.1
    volumes:
      - ../config/searxng-settings.yml:/etc/searxng/settings.yml:ro
      - ../config/searxng-limiter.toml:/etc/searxng/limiter.toml:ro
    networks:
      - squid-internal
      - squid-egress
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: "0.5"
    depends_on:
      valkey:
        condition: service_healthy
      squid:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/"]
      interval: 30s
      timeout: 5s
      retries: 3
```

OpenClaw `depends_on` adds `searxng`:
```yaml
    depends_on:
      squid:
        condition: service_healthy
      searxng:
        condition: service_healthy
```

### SXG-02: SearXNG Settings — Developer Engines

```yaml
use_default_settings: true

server:
  port: 8080
  bind_address: "0.0.0.0"
  secret_key: "${SEARXNG_SECRET}"

search:
  safe_search: 0
  autocomplete: "duckduckgo"
  default_lang: "en"
  formats:
    - html
    - json    # Required for OpenClaw API integration

redis:
  url: "${SEARXNG_VALKEY_URL}"

engines:
  # --- Enabled: Developer-relevant ---
  - name: google
    disabled: false
  - name: duckduckgo
    disabled: false
  - name: github
    disabled: false
  - name: stackoverflow
    disabled: false
  - name: arxiv
    disabled: false
  - name: wikipedia
    disabled: false
  - name: npm
    disabled: false
  - name: pypi
    disabled: false
  - name: dockerhub
    disabled: false

  # --- Disabled: Not developer-relevant ---
  - name: bing
    disabled: true
  - name: yahoo
    disabled: true
  - name: yandex
    disabled: true
  - name: baidu
    disabled: true
```

### SXG-03: SearXNG Limiter — Disable Bot Detection

```toml
[botdetection]
enabled = false

[rate_limit]
requests_per_second = 100
requests_per_minute = 6000
```

Bot detection must be disabled for AI agent usage (automated queries).

### SXG-04: Squid ACL — Add Search Engine Domains

```squid
# Search engines (for SearXNG aggregation)
acl search_engines dstdomain .google.com
acl search_engines dstdomain .googleapis.com
acl search_engines dstdomain duckduckgo.com
acl search_engines dstdomain .bing.com
acl search_engines dstdomain api.github.com
acl search_engines dstdomain .stackoverflow.com
acl search_engines dstdomain .stackexchange.com
acl search_engines dstdomain arxiv.org
acl search_engines dstdomain .wikipedia.org
acl search_engines dstdomain registry.npmjs.org
acl search_engines dstdomain pypi.org
acl search_engines dstdomain hub.docker.com

http_access allow CONNECT SSL_ports search_engines
```

Added before `http_access deny all`.

### SXG-05: setup.sh — Configure OpenClaw

After onboard, add:
```bash
docker compose run --rm -T --entrypoint "" \
    -e OPENCLAW_HOME= \
    openclaw openclaw config set plugins.entries.searxng.config.webSearch.baseUrl "http://searxng:8080" 2>/dev/null || true
```

### SXG-06: .env.example

```bash
# SearXNG web search (auto-generated if not set)
# SEARXNG_SECRET=your-random-secret-here
```

---

## 6. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Search engine domains change | Low | Medium | Monitor, update Squid ACL |
| SearXNG rate-limited by Google | Medium | Low | DuckDuckGo as fallback, caching reduces requests |
| Search results contain misleading info | Medium | Low | Agent has codebase context, cross-references |
| Increased Squid log volume | Low | Low | Log rotation already in place |
| SearXNG container OOM on complex queries | Low | Low | 512M limit, health check restarts |

---

## 7. Resource Impact

| Service | Memory | CPU | Disk |
|---------|--------|-----|------|
| SearXNG | 512M | 0.5 | ~1 GB (image) |
| Valkey | 128M | 0.25 | Minimal (cache) |
| **Total** | **640M** | **0.75** | **~1 GB** |

Minimal impact on a 24GB Mac. Total Docker memory: existing (~1.5G) + SearXNG (~0.6G) = ~2.1G.

---

## 8. Testing Strategy

| Test | How | Expected |
|------|-----|----------|
| SearXNG health | `curl http://localhost:8080/` | HTML page |
| JSON API | `curl "http://searxng:8080/search?q=test&format=json"` from container | JSON results |
| Squid allows search engines | Check `logs/squid/access.log` for CONNECT to google.com | TCP_TUNNEL/200 |
| Squid blocks non-whitelisted | `curl --proxy squid:3128 https://evil.com` from container | 403 |
| OpenClaw web_search | Ask agent "search for fastify rate limiting" | Structured results |
| Slack integration | Ask in Slack "@Claw search for Node.js best practices" | Agent responds with search results |

---

## 9. Out of Scope

- Image search (not needed for developer workflow)
- Video search (not needed)
- News aggregation (can add later)
- Custom search engine plugins (not needed for v1)
- SearXNG UI exposure (internal only, no port published)

---

## 10. Rollback

Remove SearXNG by:
1. Remove `searxng` and `valkey` from docker-compose.yml
2. Revert Squid ACL changes
3. Remove `plugins.entries.searxng` from openclaw.json
4. No data loss — SearXNG is stateless (cache only)
