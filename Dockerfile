# syntax=docker/dockerfile:1
# =============================================================================
# Shape Popper - imagen de la aplicación (backend Express + frontend estático)
# El frontend (src/public) lo sirve el mismo proceso Express, por eso backend y
# frontend forman un único componente con un único Dockerfile.
# =============================================================================

# Versiones exactas de las imágenes base (nunca "latest").
# Node 22 = LTS. El Alpine del runtime coincide con el de la imagen de Node.
ARG NODE_IMAGE=node:22.23.5-alpine3.24
ARG RUNTIME_IMAGE=alpine:3.24.4

# -----------------------------------------------------------------------------
# Stage 1 (deps): instala solo las dependencias de producción con npm
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS deps
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
    && npm cache clean --force

# -----------------------------------------------------------------------------
# Stage 2 (runner): Alpine limpio + binario de Node + node_modules
# No se hereda de la imagen node:*, así la imagen final NO incluye npm, npx,
# yarn ni corepack (herramientas de build que no se usan en runtime y que
# aportan la mayoría de las CVEs de la imagen oficial).
# -----------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS runner

# Parches de seguridad de Alpine + librerías que necesita el binario de Node +
# usuario sin privilegios (uid 1000)
RUN apk upgrade --no-cache \
    && apk add --no-cache libstdc++ libgcc \
    && addgroup -g 1000 -S node \
    && adduser -u 1000 -S -G node -H -h /app node

COPY --from=deps /usr/local/bin/node /usr/local/bin/node

WORKDIR /app

# Build args para diferenciar las imágenes Blue/Green
ARG APP_VERSION=v1.0.0
ARG APP_COLOR=blue

ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${APP_VERSION} \
    APP_COLOR=${APP_COLOR}

# Los archivos pertenecen a root y son solo lectura para el usuario "node":
# el proceso no puede modificar su propio código.
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src/ ./src/

# Seguridad: se ejecuta con el usuario sin privilegios "node"
USER node

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/healthz || exit 1

CMD ["node", "src/server.js"]
