FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pin Claw version - update deliberately, not automatically
ARG OPENCLAW_VERSION=2026.4.2
RUN npm install -g openclaw@${OPENCLAW_VERSION} && \
    # Install optional peer dependencies required by OpenClaw plugins.
    # These are not bundled with openclaw but imported at runtime.
    # Install into openclaw's own node_modules so module resolution works.
    cd /usr/local/lib/node_modules/openclaw && npm install @slack/bolt @slack/web-api @slack/socket-mode grammy

RUN useradd -m -s /bin/bash openclaw && \
    mkdir -p /openclaw/.ssh /openclaw/data /openclaw/logs && \
    chown -R openclaw:openclaw /openclaw && \
    mkdir -p /home/openclaw/.openclaw && \
    chown openclaw:openclaw /home/openclaw/.openclaw

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER openclaw
WORKDIR /openclaw

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
