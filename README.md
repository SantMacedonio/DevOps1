# Shape Popper: Despliegue Blue/Green en Kubernetes

Juego web incremental / clicker utilizando una estrategia de **despliegue Blue/Green** en **Kubernetes (Minikube)**, empaquetado con **Docker** y con persistencia de estado respaldada por **Redis**.

Participantes: Santiago Aurrecochea

---

## Descripción General

El proyecto desacopla completamente el frontend y la lógica de juego (pods sin estado) de la base de datos (Redis con almacenamiento persistente). Esto permite actualizar la aplicación entre versiones mayores o realizar rollbacks instantáneos sin interrumpir la partida ni perder el progreso del jugador.

### Arquitectura

```
                 navegador
                     │  http://<minikube-ip>:30080
                     ▼
        ┌──────────────────────────┐
        │ Service shape-game-service│  NodePort · selector: version=blue|green
        └────────────┬─────────────┘
          (switch)   │
       ┌─────────────┴──────────────┐
       ▼                            ▼
┌──────────────────┐        ┌──────────────────┐
│ shape-game-blue  │        │ shape-game-green │   Deployments (2 réplicas c/u)
│ shape-game:v1    │        │ shape-game:v2    │   Express: API + frontend estático
└────────┬─────────┘        └────────┬─────────┘
         └────────────┬──────────────┘
                      ▼
            ┌──────────────────┐
            │ redis-service    │  ClusterIP :6379
            │ shape-redis:1.0.0│  Deployment (1 réplica)
            └────────┬─────────┘
                     ▼
              PVC redis-pvc (1Gi, AOF)
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
| Helm *(para Kyverno y Falco)* | 3.x |
| KubeLinter *(opcional)* | 0.8 · si no está instalado se usa el contenedor `stackrox/kube-linter` |
| Semgrep | No hace falta instalarlo: se usa el contenedor `semgrep/semgrep:1.186.0` |

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

3. **Desplegar Redis y la versión Blue inicial:**
   ```powershell
   .\scripts\deploy.ps1       # ./scripts/deploy.sh
   ```

4. **Abrir el juego en el navegador:**
   ```bash
   minikube service shape-game-service
   ```

5. **Cambiar a la versión Green:**
   ```powershell
   .\scripts\switch-to-green.ps1   # ./scripts/switch-to-green.sh
   ```
   *Al refrescar la página, la interfaz cambia al tema verde y desbloquea el Prestigio sin perder tus puntos acumulados.*

6. **Rollback a Blue (si fuera necesario):**
   ```powershell
   .\scripts\switch-to-blue.ps1    # ./scripts/switch-to-blue.sh
   ```

7. **Eliminar todo:**
   ```powershell
   .\scripts\cleanup.ps1           # ./scripts/cleanup.sh
   ```

### Verificar el despliegue

```bash
kubectl get pods,svc -l app=shape-game          # todos los pods en Running 1/1
kubectl port-forward svc/shape-game-service 8080:80
curl http://localhost:8080/readyz                # {"status":"ready","color":"blue",...,"redis":"connected"}
curl http://localhost:8080/api/version           # versión y color activos
```

Para comprobar que los contenedores **no** corren como root:

```bash
kubectl exec deploy/shape-game-blue -- id   # uid=1000(node)
kubectl exec deploy/redis -- id             # uid=999(redis)
```

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

El script crea un Job **dentro del cluster** ([`k8s/loadgen/`](k8s/loadgen/)) que simula jugadores contra `shape-game-service`: consultan su estado, guardan progreso, compran mejoras y de vez en cuando intentan ascender.

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

## Solución de problemas

**Redis en `CrashLoopBackOff` con `Permission denied` sobre `appendonly.aof`.** Pasa si el PVC `redis-pvc` contiene datos de una versión anterior del proyecto, en la que Redis corría como root. Para pasarle los archivos al usuario `redis` hace falta un pod que corra como root. Como Kyverno lo bloquea, primero se aplica una excepción puntual ([`k8s/security/exceptions/redis-chown.yaml`](k8s/security/exceptions/redis-chown.yaml)) que solo permite ese pod:

```bash
kubectl apply -f k8s/security/exceptions/redis-chown.yaml
kubectl scale deploy/redis --replicas=0
kubectl run redis-chown --rm -i --restart=Never --image=shape-redis:1.0.0 --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"c","image":"shape-redis:1.0.0","command":["chown","-R","999:1000","/data"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}},"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"redis-pvc"}}]}}'
kubectl scale deploy/redis --replicas=1
kubectl delete -f k8s/security/exceptions/redis-chown.yaml
```

Otra opción, si no importa perder las partidas guardadas, es borrar el PVC con `kubectl delete pvc redis-pvc` y volver a ejecutar `deploy`.

**Prometheus no muestra los pods de la app en *Targets*.** Verificá que los pods tengan la anotación `prometheus.io/scrape: "true"` con `kubectl get pod -l app=shape-game -o yaml | grep prometheus.io`. Si se cambió `k8s/monitoring/prometheus.yaml`, volvé a ejecutar `deploy-monitoring`, que recarga la configuración.

**Un `kubectl apply` falla con `admission webhook "vpol.validate.kyverno.svc-fail" denied the request`.** Es Kyverno rechazando un recurso que no cumple alguna política; el mensaje dice cuál y por qué. Si en cambio dice que el webhook *no responde*, Kyverno no está corriendo (las políticas usan `failurePolicy: Fail`). Revisá `kubectl get pods -n kyverno`.

**Grafana o Prometheus quedan en `Pending`.** Minikube no tiene recursos suficientes. Recrealo con más memoria: `minikube delete` y luego `minikube start --memory=4096 --cpus=2`.

**Pods en `ErrImageNeverPull` o `ImagePullBackOff`.** Las imágenes no están dentro de Minikube. Con Minikube encendido, volvé a ejecutar `build`.
