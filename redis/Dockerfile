# syntax=docker/dockerfile:1
# =============================================================================
# Shape Popper - Redis (servicio auxiliar de persistencia)
#
# Multi-stage para no duplicar paquetes:
#   1. "patched": la imagen oficial + "apk upgrade" (parches de seguridad de
#      Alpine publicados después de la imagen base, por ejemplo OpenSSL).
#   2. Imagen final: se copia el sistema de archivos ya actualizado a una
#      imagen vacía, en una sola capa. Si se hiciera "apk upgrade" en una sola
#      etapa, las versiones viejas de los paquetes seguirían ocupando lugar en
#      la capa base (Dive lo mide como espacio desperdiciado).
# Como "FROM scratch" no hereda la configuración de la imagen oficial, se
# vuelve a declarar (PATH, entrypoint, usuario, puerto, volumen).
# =============================================================================
FROM redis:7.4.12-alpine3.22 AS patched
RUN apk upgrade --no-cache

FROM scratch
COPY --from=patched / /

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    REDIS_VERSION=7.4.12

COPY --chown=redis:redis redis.conf /usr/local/etc/redis/redis.conf

# Seguridad: Redis corre como el usuario sin privilegios "redis" (uid 999)
USER redis

WORKDIR /data
VOLUME /data
EXPOSE 6379

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD redis-cli ping | grep -q PONG || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]
