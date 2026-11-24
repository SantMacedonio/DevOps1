# Shape Popper: Despliegue Blue/Green en Kubernetes

Juego web incremental / clicker utilizando una estrategia de **despliegue Blue/Green** en **Kubernetes (Minikube)**, empaquetado con **Docker** y con persistencia de estado respaldada por **Redis**.

Participantes: Santiago Aurrecochea

---

## Descripción General

El proyecto desacopla completamente el frontend y la lógica de juego (pods sin estado) de la base de datos (Redis con almacenamiento persistente). Esto permite actualizar la aplicación entre versiones mayores o realizar rollbacks instantáneos sin interrumpir la partida ni perder el progreso del jugador.

### Arquitectura

Todo lo que está dentro del recuadro lo despliega la **Helm Chart** ([`helm-chart/`](helm-chart/)) como una release (en prod: `shape-game`, namespace `default`).

```
        navegador ── http://shape-game.local (Ingress) ── o ── NodePort :30080
                                       │
   ┌───────────────────────────────────┼────────────────────────────────────┐
   │ release Helm "shape-game"         ▼                                    │
   │                  ┌──────────────────────────────┐                      │
   │                  │ Service shape-game           │  selector: version = │
   │                  │ (app.activeColor)            │  blue | green        │
   │                  └──────────────┬───────────────┘                      │
   │                    (switch)     │                                      │
   │              ┌──────────────────┴───────────────┐                      │
   │              ▼                                  ▼                      │
   │   ┌────────────────────┐            ┌────────────────────┐             │
   │   │ shape-game-blue    │            │ shape-game-green   │ Deployments │
   │   │ shape-game:v1      │            │ shape-game:v2      │ Express:    │
   │   └─────────┬──────────┘            └─────────┬──────────┘ API + web   │
   │             └──────────────┬───────────────────┘   ▲ ConfigMap         │
   │                            ▼                            shape-game-config
   │                 ┌──────────────────────┐                               │
   │                 │ shape-game-redis     │  ClusterIP :6379              │
   │                 │ shape-redis:1.0.0    │  ▲ ConfigMap (redis.conf)     │
   │                 └──────────┬───────────┘                               │
   │                            ▼                                           │
   │                 PVC shape-game-redis-data (1Gi, AOF)                   │
   └────────────────────────────────────────────────────────────────────────┘
```

### Componentes y contenedores

| Componente | Imagen | Dockerfile | Descripción |
| :--- | :--- | :--- | :--- |
| App (backend + frontend) | `shape-game:v1` / `shape-game:v2` | [`Dockerfile`](Dockerfile) | Node.js 22 + Express. Sirve la API (`/api/*`), las probes (`/healthz`, `/readyz`), las métricas (`/metrics`) y el frontend estático (`src/public`). |
| Redis | `shape-redis:1.0.0` | [`redis/Dockerfile`](redis/Dockerfile) | Redis 7.4 con [`redis.conf`](redis/redis.conf) propio (AOF) y usuario no root. |

Prometheus y Grafana usan sus imágenes oficiales con versión fija y sin modificaciones. Son herramientas de la plataforma de monitoreo, no componentes de la aplicación. El generador de tráfico reutiliza la imagen de la app, que trae `sh` y `wget`.

El frontend no tiene un contenedor propio porque son archivos estáticos que sirve el mismo proceso Express. Así, cada versión (blue o green) despliega juntos el frontend y el backend que le corresponden.

---

## Diferencias entre Versiones (Blue vs. Green)

| Característica | Versión Blue (`v1.0.0`) | Versión Green (`v2.0.0`) |
| :--- | :--- | :--- |
| **Rol en el ciclo** | Versión inicial en producción. | Nueva versión / actualización. |
| **Mecánica Principal** | Clics en polígonos, mejoras de radio AoE, cadencia y daño. | Misma base + nuevas mecánicas avanzadas. |
| **Sistema de Prestigio** | Deshabilitado (pestaña bloqueada, API 403). | **Ascensión** habilitada: reinicia la partida a cambio de **Fragmentos Prismáticos** con multiplicador global permanente. |
| **Torretas Defensivas** | No disponibles en la tienda. | Desbloqueables tras realizar el primer prestigio (disparan láseres automáticos desde las esquinas). |

---

## Cómo Ejecutar el Proyecto

### Prerrequisitos

Versiones probadas:

| Herramienta | Versión |
| :--- | :--- |
| Docker Desktop (Docker Engine) | 28.5 |
| Minikube | Kubernetes 1.37 |
| kubectl | 1.34+ |
| Trivy *(opcional, para el análisis)* | 0.76 · si no está instalado se usa el contenedor `aquasec/trivy` |
| Dive *(opcional, para el análisis)* | 0.13 · si no está instalado se usa el contenedor `wagoodman/dive` |
| Helm | 4.3 (los scripts usan opciones de Helm 4) |
| KubeLinter *(opcional)* | 0.8 · si no está instalado se usa el contenedor `stackrox/kube-linter` |
| Semgrep | No hace falta instalarlo: se usa el contenedor `semgrep/semgrep:1.186.0` |
| Jenkins *(CI/CD)* | No hace falta instalarlo: corre en un contenedor con todas sus herramientas ([`jenkins/Dockerfile`](jenkins/Dockerfile)). Necesita una cuenta gratuita de [Snyk](https://snyk.io) |

Todos los scripts se pueden ejecutar desde cualquier carpeta. Están en `scripts/` en dos versiones: `.ps1` para Windows PowerShell y `.sh` para Linux, macOS, WSL o Git Bash.

1. **Iniciar Minikube:**
   ```bash
   minikube start
   ```

2. **Compilar las imágenes y cargarlas en Minikube:**
   ```powershell
   .\scripts\build.ps1        # Linux/macOS: ./scripts/build.sh
   ```
   El script construye `shape-game:v1`, `shape-game:v2` y `shape-redis:1.0.0` en el Docker local y las carga en Minikube con `minikube image load`.

3. **Desplegar con Helm** (app blue y green + Redis). El script hace `helm upgrade --install`, espera a que los pods estén listos y corre `helm test`:
   ```powershell
   .\scripts\deploy.ps1                  # producción: release "shape-game" en "default"
   .\scripts\deploy.ps1 -Env dev         # desarrollo: release "shape-game-dev" en "shape-dev"
   # Linux/macOS: ./scripts/deploy.sh [prod|dev]
   ```
   O directamente con Helm (ver [Despliegue con Helm](#despliegue-con-helm)):
   ```bash
   helm install shape-game ./helm-chart -f helm-chart/values-prod.yaml
   ```

4. **Abrir el juego en el navegador:**
   ```bash
   minikube service shape-game          # prod (NodePort 30080)
   minikube service shape-game-dev -n shape-dev   # dev (NodePort 30081)
   ```

5. **Cambiar a la versión Green** (un `helm upgrade` que solo cambia `app.activeColor`):
   ```powershell
   .\scripts\switch-to-green.ps1   # ./scripts/switch-to-green.sh   (agregar "dev" para ese entorno)
   ```
   *Al refrescar la página, la interfaz cambia al tema verde y desbloquea el Prestigio sin perder tus puntos acumulados.*

6. **Volver a Blue** (si fuera necesario):
   ```powershell
   .\scripts\switch-to-blue.ps1    # ./scripts/switch-to-blue.sh
   helm rollback shape-game        # alternativa: volver a la revisión anterior de Helm
   ```

7. **Eliminar todo:**
   ```powershell
   .\scripts\cleanup.ps1           # ./scripts/cleanup.sh
   ```

### Verificar el despliegue

```bash
helm list -A                                     # releases instaladas
kubectl get pods -l app.kubernetes.io/instance=shape-game   # todos los pods en Running 1/1
helm test shape-game --logs                      # el Service responde, el frontend da 200 y Redis está conectado
kubectl port-forward svc/shape-game 8080:80
curl http://localhost:8080/api/version           # versión y color activos
```

Para comprobar que los contenedores **no** corren como root:

```bash
kubectl exec deploy/shape-game-blue -- id    # uid=1000(node)
kubectl exec deploy/shape-game-redis -- id   # uid=999(redis)
```

---

## Despliegue con Helm

La Chart [`helm-chart/`](helm-chart/) despliega todo el proyecto: las dos versiones de la app y Redis. Prometheus, Grafana, Kyverno y Falco quedan afuera a propósito. Son herramientas de plataforma que se instalan una vez por cluster con sus propios scripts, no en cada despliegue de la app.

```
helm-chart/
├── Chart.yaml
├── values.yaml            # valores por defecto: alcanza con "helm install <nombre> ./helm-chart"
├── values-dev.yaml        # entorno de desarrollo
├── values-prod.yaml       # entorno de producción
└── templates/
    ├── _helpers.tpl       # nombres, etiquetas y securityContext comunes
    ├── NOTES.txt          # instrucciones que se muestran después de instalar
    ├── app-configmap.yaml     ├── redis-configmap.yaml   (redis.conf)
    ├── app-deployment.yaml    ├── redis-deployment.yaml
    ├── app-service.yaml       ├── redis-service.yaml
    ├── ingress.yaml           ├── redis-pvc.yaml
    └── tests/test-connection.yaml   # helm test
```

- **Un Deployment por color:** `app-deployment.yaml` recorre `app.versions` y genera un Deployment por cada versión habilitada.
- **El switch:** el Service apunta a `app.activeColor`. Si se pide un color que no existe o está deshabilitado, la Chart falla con un mensaje claro en vez de desplegar un Service sin pods.
- **Reinicio automático:** los Deployments llevan el *checksum* de su ConfigMap, así un cambio de configuración reinicia los pods con `helm upgrade`.
- **El PVC de Redis sobrevive al `uninstall`:** tiene `helm.sh/resource-policy: keep`, para no perder partidas por accidente. `cleanup` lo borra explícitamente.

### Parámetros principales (`values.yaml`)

| Parámetro | Por defecto | Descripción |
| :--- | :--- | :--- |
| `app.activeColor` | `blue` | Versión que recibe el tráfico (`blue` o `green`) |
| `app.port` | `3000` | Puerto del contenedor |
| `app.versions.<color>.enabled` / `.replicas` | `true` / `1` | Si se despliega esa versión y con cuántas réplicas |
| `app.versions.<color>.image.repository` / `.tag` | `shape-game` / `v1`, `v2` | Imagen de cada versión |
| `app.resources` | `50m`–`200m` CPU, `64Mi`–`256Mi` | Requests y limits de la app |
| `app.extraConfig` | `NODE_ENV: production` | Variables extra en el ConfigMap |
| `service.type` / `.port` / `.nodePort` | `NodePort` / `80` / `30080` | Exposición del Service |
| `ingress.enabled` / `.host` / `.className` | `false` / `shape-game.local` / `nginx` | Ingress |
| `redis.image.*`, `redis.resources`, `redis.maxmemory`, `redis.appendonly` | `shape-redis:1.0.0`, …, `200mb`, `true` | Redis |
| `redis.persistence.enabled` / `.size` | `true` / `1Gi` | PVC o `emptyDir` |
| `monitoring.scrape` | `true` | Anotaciones para Prometheus |
| `tests.enabled` | `true` | Pod de `helm test` |

### Entornos

| | `values-dev.yaml` | `values-prod.yaml` |
| :--- | :--- | :--- |
| Release / namespace | `shape-game-dev` / `shape-dev` | `shape-game` / `default` |
| Réplicas por color | 1 | 2 |
| Recursos de la app | `25m`–`150m` CPU, `48Mi`–`128Mi` | `50m`–`200m` CPU, `64Mi`–`256Mi` |
| Acceso | NodePort `30081` | **Ingress** `shape-game.local` + NodePort `30080` |
| Redis | Sin PVC (`emptyDir`), sin AOF, `maxmemory 64mb` | PVC 1Gi, AOF, `maxmemory 200mb` |
| `NODE_ENV` | `development` | `production` |
| Métricas para Prometheus | No | Sí |

Los dos entornos pueden convivir en el cluster.

```bash
helm install shape-game ./helm-chart -f helm-chart/values-prod.yaml
helm install shape-game-dev ./helm-chart -f helm-chart/values-dev.yaml -n shape-dev --create-namespace
```

### Blue/Green y rollback con Helm

```bash
helm upgrade shape-game ./helm-chart --reset-then-reuse-values --set app.activeColor=green --wait
helm history shape-game      # cada switch queda como una revisión
helm rollback shape-game     # vuelve a la revisión anterior
```

`--reset-then-reuse-values` conserva los valores de la release (por ejemplo, los de `values-prod.yaml`) y solo cambia el color.

### Ingress

En producción la app se expone con un Ingress (host `shape-game.local`) a través del Ingress Controller de minikube:

```bash
minikube addons enable ingress
minikube tunnel            # en otra terminal; en Windows puede pedir permisos de administrador
```

Para abrir `http://shape-game.local` en el navegador, agregá `127.0.0.1 shape-game.local` al archivo `hosts` (`C:\Windows\System32\drivers\etc\hosts`). Para probarlo sin tunnel ni `hosts`:

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8088:80
curl -H "Host: shape-game.local" http://localhost:8088/api/version
```

El namespace `ingress-nginx` está excluido de las políticas de Kyverno: el addon de minikube no define `requests` ni `limits` y la política lo bloqueaba.

---

## Calidad de las imágenes (Trivy + Dive)

```powershell
.\scripts\scan.ps1     # ./scripts/scan.sh   (requiere haber corrido build antes)
```

Para cada imagen, el script corre **Trivy** (vulnerabilidades) y **Dive** en modo CI (eficiencia y desperdicio entre capas, con los umbrales de [`.dive-ci`](.dive-ci)). También registra el tamaño y las capas con `docker history`. Las salidas quedan en [`reports/scans/`](reports/scans/).

Para explorar las capas de forma interactiva con Dive:

```powershell
dive shape-game:v1
# o sin instalar Dive:
docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock wagoodman/dive:v0.13.1 shape-game:v1
```

El reporte con el tamaño, las capas, la comparación antes/después y las observaciones de optimización está en **[`reports/image-analysis.md`](reports/image-analysis.md)**.

### Buenas prácticas aplicadas

- **Versiones exactas** en todas las imágenes base, sin `latest` ni tags flotantes: `node:22.23.5-alpine3.24`, `alpine:3.24.4` y `redis:7.4.12-alpine3.22`.
- **Multi-stage build** en la app: npm solo existe en la etapa de build, y la imagen final es Alpine + binario de Node + `node_modules`.
- **Usuarios no root**: `node` (uid 1000) y `redis` (uid 999), en el Dockerfile (`USER`) y en Kubernetes (`securityContext.runAsNonRoot`).
- **Hardening en Kubernetes**: `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` y `seccompProfile: RuntimeDefault`.
- **Builds reproducibles**: `npm ci` con `package-lock.json`, `.dockerignore` y `.gitattributes`. Este último fuerza saltos de línea LF en los `.sh`, para que funcionen en Linux aunque el repo se clone en Windows.

---

## Monitoreo y observabilidad (Prometheus + Grafana)

```
 pods shape-game (blue y green) ── GET /metrics ──► Prometheus ──► Grafana
        namespace default              (scrape 15s)   namespace monitoring
```

### Métricas de la app (`GET /metrics`)

La app usa [`@prometheus-io/client`](https://github.com/prometheus/client_js), el sucesor oficial de `prom-client`. Las métricas se definen en [`src/metrics.js`](src/metrics.js). Todas las series llevan las etiquetas `color` (blue o green) y `app_version`.

| Métrica | Tipo | Uso |
| :--- | :--- | :--- |
| `http_requests_total{method,route,status_code}` | Counter | RPS |
| `http_request_duration_seconds{method,route,status_code}` | Histogram | Latencia promedio y p95 |
| `process_cpu_seconds_total`, `process_resident_memory_bytes` | Default metrics | CPU y memoria por pod |
| `shape_game_shapes_popped_total` | Counter | **Negocio:** figuras destruidas |
| `shape_game_points_earned_total` | Counter | **Negocio:** energía generada |
| `shape_game_upgrades_purchased_total{upgrade}` | Counter | **Negocio:** mejoras compradas, por tipo |
| `shape_game_prestige_ascensions_total` | Counter | **Negocio:** ascensiones (solo Green) |
| `shape_game_active_players` | Gauge | **Negocio:** jugadores activos en los últimos 5 minutos |
| `shape_game_redis_connected` | Gauge | Estado de la conexión con Redis |

Detalles de diseño:

- La etiqueta `route` guarda el patrón de Express (`/api/state/:playerId`) y no la URL real. Si guardara la URL, cada jugador generaría una serie nueva.
- Las métricas de negocio que dependen del estado del jugador (figuras, energía, jugadores activos) se calculan contra Redis. Como el Service reparte las peticiones de un mismo jugador entre varios pods, calcularlas en la memoria de cada pod contaría de más.

### Despliegue

```powershell
.\scripts\deploy-monitoring.ps1           # ./scripts/deploy-monitoring.sh
minikube service prometheus -n monitoring # Status -> Targets: los 4 pods de la app en UP
minikube service grafana -n monitoring    # dashboard "Shape Popper - Blue/Green"
```

| Componente | Manifiesto | Detalles |
| :--- | :--- | :--- |
| Prometheus `v3.16.0` | [`k8s/monitoring/prometheus.yaml`](k8s/monitoring/prometheus.yaml) | Descubre los pods con `kubernetes_sd_configs` (`role: pod`) y la anotación `prometheus.io/scrape: "true"`. El RBAC es mínimo: un `Role` que solo puede leer pods del namespace `default`. Retención de 1 día. NodePort `30090`. |
| Grafana `13.3.1` | [`k8s/monitoring/grafana.yaml`](k8s/monitoring/grafana.yaml) | La fuente de datos Prometheus y el dashboard se cargan solos al iniciar (*provisioning*). NodePort `30030`. |

Prometheus scrapea **cada pod**, no el Service. El Service manda todo el tráfico a una sola versión y elige un pod al azar en cada petición. Scrapeando los pods, el dashboard muestra blue y green por separado, y se ve el tráfico pasar de uno a otro durante el switch.

**Acceso a Grafana:** el dashboard se puede ver sin login, en modo solo lectura. Para editarlo, el usuario es `admin`. La contraseña la genera aleatoriamente `deploy-monitoring` y se guarda en el Secret `grafana-admin`. El script la muestra al terminar, y también se puede consultar con:

```bash
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

### Dashboard ([`grafana/dashboard.json`](grafana/dashboard.json))

| Sección | Paneles |
| :--- | :--- |
| Resumen | Versión que recibe tráfico, RPS, latencia promedio, jugadores activos |
| Tráfico y latencia | RPS por versión (blue o green), latencia promedio y p95, RPS por ruta y código HTTP |
| Recursos por pod | CPU y memoria de cada pod, con el `limit` del contenedor como línea de referencia |
| Métricas de negocio | Figuras destruidas por segundo, mejoras compradas por tipo, ascensiones de prestigio, energía generada por minuto |
| Estado de los targets | Tabla de pods scrapeados (`up`) y su conexión con Redis |

`deploy-monitoring` convierte el archivo en un ConfigMap, así que `grafana/dashboard.json` es la única fuente del dashboard. Para modificarlo:

1. Editarlo en Grafana con el usuario admin.
2. Exportarlo con **Export → Export as JSON**, dejando **desactivada** la opción *Export for sharing externally*, para que siga apuntando a la fuente de datos `uid: prometheus`.
3. Reemplazar `grafana/dashboard.json` con el archivo exportado y volver a correr `deploy-monitoring`.

### Generar tráfico para la demo

```powershell
.\scripts\generate-traffic.ps1 -Duration 300 -Players 8   # ./scripts/generate-traffic.sh 300 8
```

El script crea un Job **dentro del cluster** ([`k8s/loadgen/`](k8s/loadgen/)) que simula jugadores contra el Service `shape-game` (release de prod): consultan su estado, guardan progreso, compran mejoras y de vez en cuando intentan ascender.

El tráfico se genera desde adentro porque `kubectl port-forward` se conecta a un único pod y no sigue el switch blue → green. Desde el cluster, en cambio, las peticiones pasan por el Service.

Para la demo: dejar el generador corriendo, ejecutar `switch-to-green` y mirar en el dashboard cómo el RPS pasa de la serie blue a la green y empiezan a aparecer ascensiones.

---

## Seguridad (DevSecOps)

El detalle de cada herramienta, qué se corrigió y qué se justificó está en **[`reports/security-report.md`](reports/security-report.md)**.

```powershell
.\scripts\security-scan.ps1      # npm audit, Semgrep, Trivy, KubeLinter -> reports/
.\scripts\install-security.ps1   # Kyverno + 3 políticas + Falco (con Helm)
.\scripts\test-policies.ps1      # intenta desplegar manifiestos no conformes -> reports/kyverno-validation.txt
.\scripts\test-falco.ps1         # acciones sospechosas en un pod -> reports/falco-event.log
```

| Área | Herramienta | Resultado | Reporte |
| :--- | :--- | :--- | :--- |
| Dependencias | npm audit | 0 vulnerabilidades | [`npm-audit.txt`](reports/npm-audit.txt) |
| Código (SAST) | Semgrep (187 reglas) + revisión manual | 0 hallazgos. Por revisión manual se corrigieron 6 puntos: `helmet`/CSP, sin CORS, validación de `playerId`, clave `constructor`, escape de `innerHTML` y límite del body | [`semgrep.txt`](reports/semgrep.txt) |
| Imágenes | Trivy | Propias: 0 vulnerabilidades y 0 secretos. Terceros (Prometheus, Grafana): HIGH documentados, sin versión corregida publicada | [`trivyreport.txt`](reports/trivyreport.txt) |
| Políticas | Kyverno 1.20 | 3 `ValidatingPolicy` en modo Deny; los 3 manifiestos no conformes se rechazan | [`kyverno-validation.txt`](reports/kyverno-validation.txt) |
| Manifiestos | KubeLinter | 0 errores | [`kubelinter.txt`](reports/kubelinter.txt) |
| Runtime | Falco 0.45 (eBPF) | Detecta shells y búsquedas de claves dentro de los pods | [`falco-event.log`](reports/falco-event.log) |

### Políticas de Kyverno ([`k8s/security/policies/`](k8s/security/policies/))

1. **`disallow-latest-tag`:** las imágenes deben tener un tag fijo distinto de `latest`.
2. **`require-requests-limits`:** todos los contenedores deben definir `requests` y `limits` de CPU y memoria.
3. **`require-non-root`:** `runAsNonRoot: true` y nunca `runAsUser: 0`.

Se aplican a todos los namespaces excepto los del sistema, `kyverno` y `falco` (Falco necesita privilegios para observar el kernel). Los manifiestos de prueba están en [`k8s/security/tests/`](k8s/security/tests/): cada uno viola una sola política, y hay uno conforme. Las pruebas usan `kubectl apply --dry-run=server`, que pasa por Kyverno como un despliegue real, pero no crea nada.

### Falco

Además de las reglas estándar, se agregó una regla propia, *"Shell en contenedor de Shape Popper"* (en [`k8s/security/falco-values.yaml`](k8s/security/falco-values.yaml)). Detecta cualquier shell que se abra dentro de un contenedor de la app, aunque no sea interactiva. Para ver las alertas en vivo:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco -f | grep '^{'
```

---

## Pipeline CI/CD (Jenkins)

El [`Jenkinsfile`](Jenkinsfile) automatiza todo el camino desde un commit hasta el despliegue en Kubernetes:

```
 1. Checkout ─► 2. Seguridad del código ─────────► 3. Build y tests ─► 4. Imagen Docker ──────► 5. Deploy con Helm
    git clone      Semgrep (SAST)    ┐ en             npm ci              docker build             color inactivo ← imagen nueva
    tag de la      Snyk (dependencias)┘ paralelo      26 tests (JUnit)    Trivy (corta si CRITICAL)  smoke test de ese color
    imagen                                                                minikube o ghcr.io       switch del tráfico
                                                                                                    helm test (rollback si falla)
```

**Blue/Green en el pipeline:** la imagen nueva siempre va al color que **no** recibe tráfico. Se prueba ahí y recién después se le pasa el tráfico, así que los colores se alternan en cada despliegue (blue → green → blue…). El color activo no se toca durante todo el proceso: sigue atendiendo a los jugadores y es la versión a la que se vuelve si algo falla. En el pipeline, el color es solo una "ranura": la versión nueva usa el tag de la imagen como versión y tiene el prestigio activado, caiga en blue o en green. La tabla de [diferencias entre versiones](#diferencias-entre-versiones-blue-vs-green) describe la demo manual con `shape-game:v1` y `v2`.

Cada etapa escribe su propio log en Jenkins y sus reportes se archivan con el build (`reports/ci/`: `semgrep.txt`, `snyk.json`, `trivy.txt`; `reports/tests/junit.xml`). La imagen se etiqueta `versión-build-commit` (por ejemplo `shape-game:1.0.0-1-a10e070`): nunca `latest`, y siempre se sabe de qué commit salió.

### Cortes de seguridad

Si alguna herramienta encuentra un problema crítico, el pipeline **se detiene en esa etapa**, explica el motivo y las etapas siguientes quedan como *skipped*. Así, nada vulnerable se construye, se publica ni se despliega.

| Etapa | Herramienta | Se detiene si… |
| :--- | :--- | :--- |
| 2 | Semgrep ([`ci/semgrep-gate.js`](ci/semgrep-gate.js)) | hay hallazgos de severidad `ERROR` en el código |
| 2 | Snyk ([`ci/snyk-summary.js`](ci/snyk-summary.js)) | alguna dependencia npm tiene una vulnerabilidad `critical` (o Snyk no puede analizar, por ejemplo por falta de token) |
| 3 | `node --test` | falla algún test |
| 4 | Trivy | la imagen tiene vulnerabilidades `CRITICAL` o **cualquier secreto** (claves, tokens, contraseñas), sin importar su severidad. Se revisa antes de publicar porque el paquete de ghcr.io es público |
| 5 | [`ci/deploy.sh`](ci/deploy.sh) | el color nuevo no responde, no se conecta a Redis o falla `helm test`. En ese caso hace además `helm rollback` a la revisión anterior |

### Levantar Jenkins y correr el pipeline

Jenkins corre en un contenedor (`shape-jenkins`) armado con [`jenkins/Dockerfile`](jenkins/Dockerfile). La imagen trae Node.js, Docker CLI, kubectl, Helm, Trivy, Snyk y Semgrep con versiones fijas. Toda la configuración está en [`jenkins/casc.yaml`](jenkins/casc.yaml) (*Jenkins Configuration as Code*): el usuario, las credenciales y el job. No hay que configurar nada a mano en la interfaz.

1. Con Minikube encendido, ejecutar el script una vez. La primera vez crea `.env.jenkins` a partir de [`.env.jenkins.example`](.env.jenkins.example):
   ```powershell
   .\scripts\jenkins-up.ps1        # ./scripts/jenkins-up.sh
   ```
2. Completar `SNYK_TOKEN=` en `.env.jenkins` (snyk.io → *Account settings* → *Auth Token*) y volver a ejecutar `jenkins-up`. Ese archivo tiene los secretos y **no se sube al repositorio**.
3. Entrar a <http://localhost:8080> con el usuario `admin` y la contraseña que muestra el script (también está en `.env.jenkins`).
4. Abrir el job **shape-game** → *Build with Parameters*.

| Parámetro | Valores | Qué hace |
| :--- | :--- | :--- |
| `DEPLOY_ENV` | `dev` *(default)* / `prod` | `dev`: release `shape-game-dev` en `shape-dev`, con la imagen nueva en los dos colores. `prod`: release `shape-game` en `default`, con Blue/Green; se elige a mano |
| `SWITCH_TRAFFIC` | `true` *(default)* / `false` | Solo en prod: pasar el tráfico al color nuevo después del smoke test. Con `false`, la versión nueva queda desplegada pero sin tráfico |
| `PUBLISH_IMAGE` | `false` *(default)* / `true` | `false`: la imagen se carga directo en Minikube. `true`: se publica en `ghcr.io/santmacedonio/shape-game` (requiere `GHCR_USER` y `GHCR_TOKEN` en `.env.jenkins`) |

Además del botón, el job revisa el repositorio cada 5 minutos (`pollSCM`) y corre solo si hay commits nuevos. Se usa *polling* porque GitHub no puede enviarle un webhook a un Jenkins que corre en una máquina local.

**Los builds automáticos despliegan en dev, nunca en prod** (*Continuous Delivery*). Cada commit pasa por todos los controles y queda funcionando en dev. A prod llega solo cuando alguien lanza el pipeline con `DEPLOY_ENV=prod`. Así, ningún cambio llega a los jugadores sin una decisión explícita. Para pausar también los despliegues en dev, se usa *Disable Project* en el job.

Para detenerlo: `.\scripts\jenkins-down.ps1`. Con `-Purge` (o `--purge`) también se borran su historial y sus permisos en Kubernetes.

### Cómo se conecta con Docker y Kubernetes

- **Docker:** el contenedor monta el socket de Docker del host para construir imágenes. En *modo local* (`PUBLISH_IMAGE=false`), la imagen se pasa a Minikube con `docker save | ctr images import`, que es lo mismo que hace `minikube image load`.
- **Kubernetes:** Jenkins no usa el kubeconfig de administrador. Usa la ServiceAccount `jenkins-deployer` ([`k8s/jenkins/rbac.yaml`](k8s/jenkins/rbac.yaml)), que solo puede gestionar los recursos de la app en los namespaces `default` y `shape-dev`. No puede tocar `kube-system` ni los namespaces de monitoreo, ni borrar las políticas de Kyverno.
- **Código:** mientras la rama no esté en GitHub, el job clona el repositorio local montado en `/repo` (`REPO_URL=file:///repo`). Por eso **solo ve los cambios que tienen commit**. Para usar GitHub, basta con cambiar `REPO_URL` y `REPO_BRANCH` en `.env.jenkins`.

### Evidencia ([`reports/jenkins/`](reports/jenkins/))

| Build | Resultado | Qué muestra |
| :--- | :--- | :--- |
| [#1](reports/jenkins/build-1-exito-prod.txt) | ✅ prod, 2 min 32 s | Pipeline completo: 0 hallazgos de Semgrep y Snyk, 26/26 tests, 0 vulnerabilidades en la imagen, green desplegada, smoke test, switch a green y `helm test` |
| [#2](reports/jenkins/build-2-detenido-por-snyk.txt) | ⛔ detenido en Snyk | Rama de prueba con `node-serialize@0.0.4` (ejecución remota de código, severidad *critical*): las etapas 3 a 5 no se ejecutan |
| [#3](reports/jenkins/build-3-rollback-automatico.txt) | ⛔ rollback en dev | El smoke test probó un pod viejo que se estaba apagando (error del script, ya corregido). Muestra el `helm rollback` automático: dev volvió a la revisión anterior sin quedar roto |
| [#4](reports/jenkins/build-4-exito-dev.txt) | ✅ dev, 1 min 5 s | El mismo despliegue en dev, con la corrección |
| [#6](reports/jenkins/build-6-alternancia-prod.txt) | ✅ prod, 1 min 8 s | Blue/Green alternado: con blue activo, la versión nueva va a green, se prueba y recién después recibe el tráfico. Blue conserva la versión anterior para volver atrás |

### Simplificaciones respecto de un entorno real

- Los builds corren en el propio controlador de Jenkins. En una empresa se usarían agentes separados, por ejemplo pods efímeros con el plugin de Kubernetes.
- Montar el socket de Docker le da a Jenkins control total del Docker del host. Las alternativas más seguras son Kaniko, BuildKit *rootless* o un agente dedicado.
- El despliegue de prod es automático. En un entorno real suele llevar una aprobación manual (`input`) o pasar antes por un entorno de staging.

---

## Solución de problemas

**Redis en `CrashLoopBackOff` con `Permission denied` sobre `appendonly.aof`.** Pasa si el PVC de Redis (`shape-game-redis-data`) contiene datos de una versión anterior del proyecto, en la que Redis corría como root. Para pasarle los archivos al usuario `redis` hace falta un pod que corra como root. Como Kyverno lo bloquea, primero se aplica una excepción puntual ([`k8s/security/exceptions/redis-chown.yaml`](k8s/security/exceptions/redis-chown.yaml)) que solo permite ese pod:

```bash
kubectl apply -f k8s/security/exceptions/redis-chown.yaml
kubectl scale deploy/shape-game-redis --replicas=0
kubectl run redis-chown --rm -i --restart=Never --image=shape-redis:1.0.0 --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"c","image":"shape-redis:1.0.0","command":["chown","-R","999:1000","/data"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}},"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"shape-game-redis-data"}}]}}'
kubectl scale deploy/shape-game-redis --replicas=1
kubectl delete -f k8s/security/exceptions/redis-chown.yaml
```

Otra opción, si no importa perder las partidas guardadas, es borrar el PVC con `kubectl delete pvc shape-game-redis-data` (con la release desinstalada) y volver a ejecutar `deploy`.

**Prometheus no muestra los pods de la app en *Targets*.** Verificá que los pods tengan la anotación `prometheus.io/scrape: "true"` con `kubectl get pod -l app=shape-game -o yaml | grep prometheus.io`. Si se cambió `k8s/monitoring/prometheus.yaml`, volvé a ejecutar `deploy-monitoring`, que recarga la configuración.

**Un `kubectl apply` falla con `admission webhook "vpol.validate.kyverno.svc-fail" denied the request`.** Es Kyverno rechazando un recurso que no cumple alguna política; el mensaje dice cuál y por qué. Si en cambio dice que el webhook *no responde*, Kyverno no está corriendo (las políticas usan `failurePolicy: Fail`). Revisá `kubectl get pods -n kyverno`.

**Grafana o Prometheus quedan en `Pending`.** Minikube no tiene recursos suficientes. Recrealo con más memoria: `minikube delete` y luego `minikube start --memory=4096 --cpus=2`.

**La etapa de Snyk falla con "Snyk no pudo completar el análisis".** Falta el token o es inválido. Completá `SNYK_TOKEN` en `.env.jenkins` y volvé a ejecutar `jenkins-up`: Jenkins lee las credenciales solo al arrancar.

**El deploy de Jenkins falla con `connection refused` o `i/o timeout` contra la API de Kubernetes.** La IP de Minikube cambió (por ejemplo, después de un `minikube delete`). Volvé a ejecutar `jenkins-up`, que regenera `.jenkins/kubeconfig` con la IP actual.

**Pods en `ErrImageNeverPull` o `ImagePullBackOff`.** Las imágenes no están dentro de Minikube. Con Minikube encendido, volvé a ejecutar `build`.
