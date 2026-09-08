# Stage 1: Build & Dependencies
FROM node:20-alpine AS deps
WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci --only=production

# Stage 2: Final Minimal Runtime Image
FROM node:20-alpine AS runner
WORKDIR /app

# Build arguments for Blue/Green image differentiation
ARG APP_VERSION=v1.0.0
ARG APP_COLOR=blue

# Set environment variables
ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${APP_VERSION} \
    APP_COLOR=${APP_COLOR}

# Security: run as non-root user
USER node

# Copy production node_modules and application source
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src/ ./src/

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/healthz || exit 1

CMD ["node", "src/server.js"]
