FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Pin Claw version - update deliberately, not automatically
ARG OPENCLAW_VERSION=2026.4.2
RUN npm install -g openclaw@${OPENCLAW_VERSION}

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
