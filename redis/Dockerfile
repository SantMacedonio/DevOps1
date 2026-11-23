# syntax=docker/dockerfile:1
# =============================================================================
# Shape Popper - Redis (servicio auxiliar de persistencia)
#
# Single-stage a propósito: Redis ya viene compilado en la imagen oficial y no
# hay artefactos de build que descartar, por lo que un multi-stage no reduciría
# el tamaño. La imagen solo agrega la configuración y fija el usuario no root.
# =============================================================================
FROM redis:7.4.12-alpine3.22

# Parches de seguridad de Alpine publicados después de la imagen base
RUN apk upgrade --no-cache

COPY --chown=redis:redis redis.conf /usr/local/etc/redis/redis.conf

# Seguridad: Redis corre como el usuario sin privilegios "redis" (uid 999)
USER redis

WORKDIR /data
VOLUME /data
EXPOSE 6379

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD redis-cli ping | grep -q PONG || exit 1

CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]
