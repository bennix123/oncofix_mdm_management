# syntax=docker/dockerfile:1

# ============================================================
# Stage 1: Builder — compile TypeScript, install native deps
# ============================================================
FROM node:18-bookworm-slim AS builder

# Build tools as fallback for better-sqlite3 native compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.build.json ./
COPY src/ ./src/
RUN npm run build

# Strip devDependencies — keep only axios + better-sqlite3
RUN npm prune --production

# ============================================================
# Stage 2: Production — minimal runtime image
# ============================================================
FROM node:18-bookworm-slim AS production

RUN apt-get update && apt-get install -y --no-install-recommends \
    iputils-ping curl procps && \
    rm -rf /var/lib/apt/lists/*

# Create oncofix user (matches systemd service config)
RUN groupadd -r oncofix && useradd -r -g oncofix -m -d /opt/oncofix oncofix

# Create all directories the agent expects
RUN mkdir -p /etc/oncofix \
             /var/lib/oncofix/backups \
             /var/log/oncofix \
             /opt/oncofix/oncofix_mdm_agent && \
    chown -R oncofix:oncofix /etc/oncofix /var/lib/oncofix /var/log/oncofix /opt/oncofix

WORKDIR /opt/oncofix/oncofix_mdm_agent

# Copy built artifacts and production node_modules from builder
COPY --from=builder --chown=oncofix:oncofix /build/dist ./dist/
COPY --from=builder --chown=oncofix:oncofix /build/node_modules ./node_modules/
COPY --from=builder --chown=oncofix:oncofix /build/package.json ./

# Default VERSION file
RUN echo "1.0.0" > /opt/oncofix/VERSION && \
    chown oncofix:oncofix /opt/oncofix/VERSION

USER oncofix

# Environment defaults
ENV NODE_ENV=production
ENV MDM_SQLITE_PATH=/var/lib/oncofix/mdm-agent.sqlite
ENV MDM_DATA_DIR=/var/lib/oncofix
ENV MDM_LOG_DIR=/var/log/oncofix
ENV MDM_LOG_FILE=/var/log/oncofix/agent.log
ENV MDM_BACKUP_DIR=/var/lib/oncofix/backups
ENV MDM_FLAG_DIR=/var/lib/oncofix

# Demo-friendly: faster intervals for live demonstration
ENV HEARTBEAT_INTERVAL_MS=60000
ENV COMMAND_POLL_INTERVAL_MS=60000
ENV UPDATE_CHECK_INTERVAL_MS=300000

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD node -e "const db=require('better-sqlite3')('/var/lib/oncofix/mdm-agent.sqlite',{readonly:true});db.prepare('SELECT 1').get();db.close()" || exit 1

CMD ["node", "dist/main.js"]
