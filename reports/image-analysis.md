# Análisis de imágenes Docker

Fecha del análisis: 2026-11-24 (imágenes reconstruidas sin caché, con `ioredis` 6 y Redis multi-stage) · Herramientas: **Trivy 0.76.1** (vulnerabilidades) y **Dive v0.13.1** (capas y eficiencia).

Las salidas completas están en [`reports/scans/`](scans/) y se regeneran con:

```powershell
.\scripts\build.ps1   # o ./scripts/build.sh
.\scripts\scan.ps1    # o ./scripts/scan.sh
```

> **Sobre los tamaños:** Docker Desktop usa el *containerd image store*, que muestra dos tamaños.
> El **tamaño en disco** (columna `SIZE` de `docker images`) incluye la imagen descomprimida.
> El **tamaño de contenido** (`docker image inspect --format '{{.Size}}'`) es el de las capas comprimidas, que es lo que se transfiere a un registry o a Minikube.

## Componentes

| Componente | Imagen | Dockerfile | Base |
|---|---|---|---|
| App (backend Express + frontend estático) | `shape-game:v1` (Blue) / `shape-game:v2` (Green) | [`Dockerfile`](../Dockerfile) | `node:22.23.5-alpine3.24` (build) → `alpine:3.24.4` (runtime) |
| Redis (persistencia) | `shape-redis:1.0.1` | [`redis/Dockerfile`](../redis/Dockerfile) | `redis:7.4.12-alpine3.22` (parches) → `scratch` (runtime, una capa) |
| Jenkins (CI/CD, no se despliega en el cluster) | `shape-jenkins:1.0.0` | [`jenkins/Dockerfile`](../jenkins/Dockerfile) | `jenkins/jenkins:2.580.2-lts-jdk21` |

El frontend no tiene una imagen propia: son archivos estáticos (`src/public`) que sirve el mismo proceso Express. Backend y frontend forman un único componente desplegable, y el blue/green versiona ambos juntos.

## Resultados

| Imagen | Tamaño en disco | Tamaño de contenido | Capas (filesystem) | Vulnerabilidades (Trivy) | Eficiencia (Dive) | Desperdicio (Dive) | Dive CI |
|---|---|---|---|---|---|---|---|
| `shape-game:v1` | **218 MB** | 54 MB | **7** | **0** | 96.0 % | 12 MB | PASS |
| `shape-game:v2` | **218 MB** | 54 MB | **7** | **0** | 96.0 % | 12 MB | PASS |
| `shape-redis:1.0.1` | **57.7 MB** | 15 MB | **3** | **0** | **100 %** | **0 B** | PASS |

`v1` y `v2` se construyen desde el mismo Dockerfile y solo cambian los `ARG` (`APP_VERSION`, `APP_COLOR`). Por eso son idénticas en tamaño y en capas.

Umbrales de Dive en modo CI ([`.dive-ci`](../.dive-ci)): eficiencia ≥ 95 %, desperdicio ≤ 20 MB y desperdicio de las capas propias ≤ 10 %.

### Capas de `shape-game:v1`

| Tamaño | Instrucción |
|---|---|
| 8.97 MB | `alpine:3.24.4` (rootfs base) |
| 9.3 MB | `RUN apk upgrade && apk add libstdc++ libgcc && adduser node` |
| 130 MB | `COPY --from=deps /usr/local/bin/node` |
| 8 kB | `WORKDIR /app` |
| 11.1 MB | `COPY --from=deps /app/node_modules` (incluye `@prometheus-io/client`, ver nota) |
| 12 kB | `COPY package.json` |
| 115 kB | `COPY src/` |

Las instrucciones `ENV`, `ARG`, `USER`, `EXPOSE`, `HEALTHCHECK` y `CMD` solo agregan metadatos y no crean capas de filesystem.

### Capas de `shape-redis:1.0.1`

| Tamaño | Instrucción |
|---|---|
| 41.3 MB | `COPY --from=patched / /`: todo el sistema de la imagen oficial **ya actualizado**, en una sola capa |
| 24.6 kB | `COPY redis.conf` |
| 4.1 kB | `WORKDIR /data` |

**Historial de esta imagen.** Al repetir el análisis el 2026-11-24, Trivy encontró en `shape-redis:1.0.0` **10 vulnerabilidades nuevas de OpenSSL** (6 MEDIUM, 4 LOW), publicadas después del primer análisis y ya corregidas en Alpine (`libcrypto3`/`libssl3` 3.5.9-r1). Hubo dos problemas en cadena:

1. **El build con caché no las corregía.** Docker reutilizaba la capa del `apk upgrade` de la vez anterior, así que la imagen nueva seguía con OpenSSL vulnerable. Por eso los scripts y el pipeline construyen ahora con `--pull --no-cache`.
2. **Sin caché, Dive la rechazaba.** Al actualizarse de verdad OpenSSL, la versión vieja seguía ocupando lugar en la capa base: eficiencia del 86 % (el mínimo es 95 %) y 66.9 MB. La solución fue el **multi-stage**: una etapa `patched` hace `apk upgrade` y la imagen final copia ese sistema ya actualizado sobre `FROM scratch`, en una sola capa. Como `scratch` no hereda la configuración de la imagen oficial, el Dockerfile vuelve a declarar `PATH`, `ENTRYPOINT`, usuario, puerto y volumen.

Resultado: de 10 capas y 10 vulnerabilidades a **3 capas, 0 vulnerabilidades y 0 bytes desperdiciados**. Se publicó con un tag nuevo (`1.0.1`) en lugar de pisar el `1.0.0`, porque un tag publicado no debería cambiar de contenido.

## Comparación antes / después (imagen de la app)

| | Original (`node:20-alpine`) | Original con Node 22 | **Optimizada** |
|---|---|---|---|
| Etapa final | `node:20-alpine` | `node:22.23.5-alpine3.24` | `alpine:3.24.4` + binario de Node |
| Tamaño en disco | 201 MB | 246 MB | **211 MB** (−35 MB, −14 %) · 218 MB con métricas¹ |
| Capas | 8 | 8 | **7** |
| CRITICAL / HIGH | **2 / 29** | 0 / 10 | **0 / 0** |
| MEDIUM / LOW | 33 / 35 | 19 / 5 | **0 / 0** |
| npm / yarn / corepack en runtime | Sí | Sí | **No** |
| Node.js con soporte | No (Node 20 EOL desde 04/2026) | Sí | Sí |

¹ La comparación corresponde al momento de optimizar la imagen (punto 1). Después, en el punto 4 (monitoreo), se agregó la librería de métricas `@prometheus-io/client`, que suma unos 5 MB a `node_modules` (incluye `@opentelemetry/api`) y no agrega vulnerabilidades.

Redis antes usaba `redis:7-alpine` (tag flotante) y **corría como root**. El `command:` del manifiesto de Kubernetes reemplazaba el entrypoint oficial, que es el que cambia al usuario `redis`. Ahora usa un tag exacto y `USER redis` (uid 999), y Kubernetes lo exige con `runAsNonRoot`.

## Optimizaciones aplicadas

1. **Multi-stage real.** La etapa `deps` usa la imagen de Node, con npm, para instalar dependencias. La etapa final parte de un Alpine limpio y copia solo el binario `node` y `node_modules`. Antes se intentó borrar npm con `rm -rf` dentro de la imagen `node:*`, pero eso **no reduce el tamaño**, porque los archivos siguen en las capas base (la imagen quedaba en 246 MB).
2. **Sin herramientas de build en runtime.** Al no incluir npm, que trae `tar`, `glob`, `minimatch`, `cross-spawn`, `sigstore`, etc., desaparecieron 1 CRITICAL y 21 HIGH. Los 7 HIGH restantes de la imagen original eran de paquetes de Alpine (OpenSSL, musl, zlib) y se resolvieron con la base nueva y `apk upgrade`.
3. **Dependencias actualizadas.** `express` pasó a 4.22.3 (con eso se corrigen `proxy-addr` y `body-parser`, CRITICAL/HIGH) y se eliminó `uuid`, que no se usaba.
4. **`npm ci --omit=dev` + `npm cache clean`.** Solo se instalan dependencias de producción, desde el lockfile, para que el build sea reproducible.
5. **Versiones exactas** en todas las imágenes base: `node:22.23.5-alpine3.24`, `alpine:3.24.4` y `redis:7.4.12-alpine3.22`.
6. **Usuario no root** en ambas imágenes (`node` uid 1000, `redis` uid 999). En Kubernetes se suma `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities: drop ALL` y `seccompProfile: RuntimeDefault`.
7. **Código de solo lectura.** Los archivos de `/app` pertenecen a root, así que el proceso `node` no puede modificarlos.
8. **`.dockerignore`.** Excluye `.git`, `node_modules`, `k8s`, `scripts`, `reports` y la documentación, para que el contexto de build sea mínimo.
9. **Build sin caché (`--pull --no-cache`).** En los scripts y en el pipeline, para que cada imagen tenga la base más reciente de su tag y un `apk upgrade` que realmente se ejecute (ver el historial de Redis).
10. **Redis multi-stage aplanado** sobre `FROM scratch`: una sola capa sin paquetes duplicados.

## Observaciones y optimizaciones posibles

- **El binario de Node ocupa la mayor parte de la imagen** (130 de 218 MB, el 60 %). Es el mayor costo y no se puede reducir sin cambiar de runtime. Node 20 pesaba 97 MB, pero ya no tiene soporte.
- **Desperdicio de 12 MB por `apk upgrade`.** Dive marca `libcrypto.so.3` y `libssl.so.3` duplicados: la versión vieja queda en la capa base y la parcheada en la capa nueva. Es un compromiso a favor de la seguridad (corrige 11 CVEs de OpenSSL y zlib). Hay dos maneras de eliminarlo:
  - Cuando se publique `alpine:3.24.5`, actualizar el tag y quitar `apk upgrade`.
  - Aplanar el runtime con un stage intermedio y `FROM scratch` + `COPY --from=stage / /`, como ya se hizo con Redis.
- **`apk upgrade` hace que el build dependa del momento en que se ejecuta.** Para una reproducibilidad estricta se pueden fijar las imágenes por *digest* (`alpine:3.24.4@sha256:...`) y las versiones de los paquetes `apk`.
- **Distroless** (`gcr.io/distroless/nodejs22-debian12:nonroot`) quitaría la shell y apk, lo que mejora la seguridad, pero no achica la imagen (Node sigue pesando lo mismo), y el `HEALTHCHECK` con `wget` dejaría de funcionar. Para este proyecto no compensa.
- **La imagen de Jenkins (`shape-jenkins`, 2.61 GB) no es multi-stage, a propósito.** Es la herramienta de CI, no un componente de la aplicación: no se despliega en el cluster. Su contenido son justamente las herramientas que el pipeline usa en tiempo de ejecución (JDK, Node.js, Docker CLI, kubectl, Helm, Trivy, Snyk y Semgrep), así que no hay artefactos de build que descartar. Lo que se cuidó es que todas tengan versión fija (kubectl, además, con verificación de su sha256) y que Jenkins corra como usuario `jenkins`, no root. Una alternativa más liviana serían agentes efímeros con una imagen por herramienta.
- **Redis sin contraseña.** Solo es accesible dentro del cluster (Service `ClusterIP`). Como mejora, se podría agregar `requirepass` leyendo un `Secret` de Kubernetes (la app ya soporta `REDIS_PASSWORD`).
- **Las vulnerabilidades cambian con el tiempo.** Estos resultados valen para la fecha del análisis. Conviene volver a correr `scripts/scan` antes de cada entrega o en un pipeline de CI.
