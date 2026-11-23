# Reporte de seguridad (DevSecOps)

Fecha: 2026-11-23 · Cluster: minikube (Kubernetes 1.37, kernel 5.15 WSL2)

| Área | Herramienta | Evidencia | Resultado |
|---|---|---|---|
| Dependencias | npm audit (npm 11.12) | [`npm-audit.txt`](npm-audit.txt) | **0 vulnerabilidades** |
| Código (SAST) | Semgrep 1.186.0, 187 reglas | [`semgrep.txt`](semgrep.txt) | **0 hallazgos** + 6 correcciones por revisión manual |
| Imágenes | Trivy 0.76.1 | [`trivyreport.txt`](trivyreport.txt) | Imágenes propias: **0 vulnerabilidades, 0 secretos**. Terceros: 22 HIGH documentados |
| Políticas K8s | Kyverno 1.20.0 | [`kyverno-validation.txt`](kyverno-validation.txt) | 3 políticas en modo **Deny**: 3/3 manifiestos no conformes rechazados y el conforme aceptado |
| Manifiestos K8s | KubeLinter 0.8.3 | [`kubelinter.txt`](kubelinter.txt) | **0 errores** (se corrigieron 2) |
| Runtime | Falco 0.45.2 | [`falco-event.log`](falco-event.log) | Shell y búsqueda de claves en un pod **detectadas** |

Para regenerar todo:

```powershell
.\scripts\security-scan.ps1     # npm audit, Semgrep, Trivy, KubeLinter
.\scripts\test-policies.ps1     # Kyverno
.\scripts\test-falco.ps1        # Falco
```

---

## 1. Seguridad en el código

### npm audit

`npm audit` no encuentra vulnerabilidades en las 4 dependencias directas (`express`, `ioredis`, `helmet` y `@prometheus-io/client`) ni en las transitivas. Ya en el punto 1 se habían actualizado `express`, para corregir `body-parser` y `proxy-addr`, y se había quitado `uuid`, que no se usaba.

### Semgrep

Se ejecutó con los conjuntos de reglas `p/javascript`, `p/nodejs`, `p/expressjs`, `p/xss`, `p/owasp-top-ten`, `p/security-audit`, `p/secrets`, `p/dockerfile` y `p/kubernetes`: 187 reglas sobre 60 archivos, entre JS, HTML, Dockerfile, YAML y scripts. Resultado: **0 hallazgos**.

> **Detalle importante:** por defecto Semgrep analiza **solo los archivos con commit en git**. Como gran parte del proyecto todavía no tenía commit, el primer análisis dejó afuera archivos como `src/metrics.js`. Se usa `--no-git-ignore` para analizarlo todo.

Que Semgrep no marque nada no significa que el código no tenga problemas. Las reglas de la comunidad buscan patrones conocidos. Por eso se hizo además una **revisión manual**, que encontró y corrigió lo siguiente:

| # | Problema | Riesgo | Corrección |
|---|---|---|---|
| 1 | `upgradeKey` se buscaba con `UPGRADES_DEF[upgradeKey]` | Con `"constructor"` o `"__proto__"` la validación pasaba, porque son propiedades que todo objeto JS hereda, y se escribían claves inesperadas en el estado del jugador | `Object.hasOwn(...)`. Probado: ahora responde 400 |
| 2 | `playerId` sin validar (solo largo ≥ 5) | Claves arbitrarias en Redis (`player:<lo que sea>`) y texto inyectado en los logs | Patrón `^[A-Za-z0-9_-]{5,64}$` en los 4 endpoints |
| 3 | Sin headers de seguridad | Clickjacking, *MIME sniffing*, XSS sin defensa en profundidad | `helmet` con una CSP estricta (`script-src 'self'`, sin `unsafe-inline`) y sin `X-Powered-By` |
| 4 | `cors()` abierto a cualquier origen | Cualquier sitio podía llamar a la API desde el navegador de un jugador | Se eliminó: el frontend se sirve desde el mismo origen, así que CORS no hace falta |
| 5 | `innerHTML` con datos del servidor (`app.js`) | XSS si esos datos alguna vez fueran manipulables | Se escapan los valores con `escapeHtml()` |
| 6 | Body JSON sin límite de tamaño | Peticiones enormes consumen memoria | `express.json({ limit: '100kb' })`. Probado: 200 KB → 413 |

Para que la CSP no necesite `'unsafe-inline'`, el único estilo inline del HTML (`style="display: none;"`) se reemplazó por el atributo `hidden`.

**Alertas que se mantienen, con su justificación:**

| Tema | Justificación |
|---|---|
| Sin protección CSRF | No hay cookies ni sesiones: el jugador se identifica con un ID guardado en `localStorage`, que el navegador no envía solo. Sin credenciales automáticas no hay CSRF. |
| El cliente informa su propio puntaje (`/api/save`) | Es una decisión de diseño del juego: la simulación corre en el navegador. Permite hacer trampa, pero no compromete el sistema. Para evitarlo habría que mover la lógica de puntos al servidor. |
| La app corre sobre HTTP, sin TLS | Es un entorno local (minikube). En producción iría detrás de un Ingress con TLS, y ahí se activaría HSTS, hoy desactivado a propósito. |

---

## 2. Seguridad en la imagen (Trivy)

### Imágenes propias: 0 vulnerabilidades

`shape-game:v1`, `shape-game:v2` y `shape-redis:1.0.0` no tienen **ninguna vulnerabilidad** (de ninguna severidad) **ni secretos** expuestos. Las medidas que lo permiten se describen en [`image-analysis.md`](image-analysis.md):

- La imagen final no incluye npm.
- Las imágenes base usan versiones exactas y actuales.
- Se aplica `apk upgrade` para incorporar los parches de Alpine.

### Imágenes de terceros: HIGH documentados

Trivy también se corrió sobre las imágenes oficiales que usa el cluster. Al momento del análisis, son las **últimas versiones publicadas**, así que no hay una versión corregida para actualizar.

| Imagen | HIGH | Vulnerabilidades | Componente afectado | Mitigación / justificación |
|---|---|---|---|---|
| `prom/prometheus:v3.16.0` | 2 | CVE-2026-78661 (DoS en `x/net/html`) | Librería Go compilada en el binario | Prometheus no procesa HTML de terceros. Solo es accesible dentro del cluster o por NodePort en minikube. Se actualiza cuando salga una versión corregida. |
| `grafana/grafana:13.3.1` | 20 | CVE-2026-78661, CVE-2026-78669 (DoS en `x/net`) · CVE-2026-78667, CVE-2026-97031 (DoS en `net/http`, `crypto/tls`) · CVE-2026-111943 (`crypto/x509`, MITM) · CVE-2026-21728, CVE-2026-28377 (Tempo) | Go stdlib y librerías de plugins incluidos | La mayoría son DoS. El de `crypto/x509` afecta conexiones TLS salientes, pero Grafana solo se conecta a Prometheus por HTTP interno. Las de Tempo no aplican, porque no se usa Tempo como fuente de datos. Grafana no está expuesto a Internet. Se actualiza cuando haya parche. |
| ~~`curlimages/curl:8.23.0`~~ | ~~32~~ | krb5 y otras librerías de Alpine | — | **Resuelto:** el generador de tráfico ahora usa la imagen de la app, que ya trae `sh` y `wget` y tiene 0 vulnerabilidades. La imagen de curl dejó de usarse. |

---

## 3. Seguridad en Kubernetes

### Kyverno: 3 políticas en modo Deny

Kyverno 1.20 declara **deprecado** el tipo clásico `ClusterPolicy`. Las políticas se escribieron con la API nueva, **`ValidatingPolicy`** (`policies.kyverno.io/v1`), que usa expresiones **CEL**, el mismo lenguaje de las *ValidatingAdmissionPolicies* nativas de Kubernetes.

| Política | Archivo | Qué exige |
|---|---|---|
| `disallow-latest-tag` | [`disallow-latest-tag.yaml`](../k8s/security/policies/disallow-latest-tag.yaml) | Todas las imágenes con tag explícito (o digest) y distinto de `latest`. Contempla registries con puerto (`localhost:5000/app` sin tag se rechaza). |
| `require-requests-limits` | [`require-requests-limits.yaml`](../k8s/security/policies/require-requests-limits.yaml) | `requests` y `limits` de CPU y memoria en todos los contenedores, incluidos los initContainers. |
| `require-non-root` | [`require-non-root.yaml`](../k8s/security/policies/require-non-root.yaml) | `runAsNonRoot: true` (a nivel pod o en cada contenedor) y prohíbe `runAsUser: 0`. |

Kyverno genera automáticamente la misma validación para los controladores (Deployment, Job, StatefulSet, etc.). Por eso un Deployment no conforme se rechaza en el `kubectl apply`, en vez de crearse y quedarse sin pods.

**Validación** ([`kyverno-validation.txt`](kyverno-validation.txt)): cada manifiesto de [`k8s/security/tests/`](../k8s/security/tests/) viola **una sola** política, y hay uno conforme.

| Manifiesto | Esperado | Resultado | Mensaje de Kyverno |
|---|---|---|---|
| `01-latest-tag.yaml` | Rechazo | ✅ Rechazado | *Prohibido usar imágenes sin tag o con la etiqueta latest… nginxinc/nginx-unprivileged:latest* |
| `02-no-resources.yaml` (Pod) | Rechazo | ✅ Rechazado | *Todos los contenedores deben definir resources.requests y resources.limits… web* |
| `03-run-as-root.yaml` | Rechazo | ✅ Rechazado | *Los contenedores no pueden ejecutarse como root…* |
| `04-compliant.yaml` | Aceptación | ✅ Aceptado | — |

Además, todos los recursos del proyecto (app, Redis, Prometheus, Grafana y el generador de tráfico) se volvieron a desplegar con las políticas activas sin ningún rechazo.

**Excepciones y exclusiones, con su justificación:**

- **Namespaces excluidos:** `kube-system`, `kube-public`, `kube-node-lease`, `kyverno` y `falco`. Los componentes del sistema y Falco necesitan privilegios. Falco corre como root porque carga un programa eBPF en el kernel para observar las llamadas al sistema.
- **`PolicyException` puntual** ([`k8s/security/exceptions/redis-chown.yaml`](../k8s/security/exceptions/redis-chown.yaml)): para la migración de permisos de Redis, que requiere un pod root una sola vez. Solo aplica a un pod llamado `redis-chown` en `default`. Se aplica antes de la migración y se borra después. Kyverno solo acepta excepciones creadas en el namespace `kyverno`, así que alguien con acceso únicamente a `default` no puede eximirse a sí mismo.
- **`failurePolicy: Fail`:** si Kyverno no responde, los pods de los namespaces controlados no se crean. Se priorizó la seguridad sobre la disponibilidad.

### KubeLinter: 0 errores

El primer análisis marcó **2 errores** (`no-anti-affinity` en blue y green). Se corrigieron con `podAntiAffinity` **preferida** (`preferredDuringScheduling…`), que reparte las réplicas en nodos distintos cuando hay más de uno. No se usó la versión obligatoria (`required…`) porque minikube tiene un solo nodo, y la segunda réplica quedaría en `Pending`.

Además, de los checks opcionales (`--add-all-built-in`) se aplicó `default-service-account`: `automountServiceAccountToken: false` en todos los pods que no usan la API de Kubernetes (todos menos Prometheus). Si alguien entra a un contenedor, no encuentra un token para hablar con el cluster.

El reporte incluye una segunda sección de **control**: KubeLinter sobre los manifiestos de prueba no conformes. Ahí marca exactamente las violaciones esperadas (`latest-tag`, `unset-cpu/memory-requirements`, `run-as-non-root`), lo que demuestra que la herramienta efectivamente analiza.

Checks opcionales que **no** se aplicaron:

| Check | Motivo |
|---|---|
| `non-isolated-pod` (NetworkPolicy) | La red por defecto de minikube no aplica NetworkPolicies, así que no tendría efecto real. En producción se agregaría una política que solo permita tráfico de la app a Redis y de Prometheus a la app. |
| `minimum-three-replicas`, `no-node-affinity` | Hay un solo nodo y recursos limitados. |
| `sorted-keys`, `required-label-owner`, `required-annotation-email`, `dnsconfig-options`, `use-namespace` | Son de estilo o convenciones organizacionales, no de seguridad. |

---

## 4. Seguridad en tiempo de ejecución (Falco)

Falco 0.45.2 (chart 9.2.2) se instaló con el driver **`modern_ebpf`**. No requiere compilar módulos del kernel y funciona sobre el kernel 5.15 de WSL2 porque tiene BTF. Los eventos se emiten en JSON.

**Regla propia** ([`falco-values.yaml`](../k8s/security/falco-values.yaml)): *"Shell en contenedor de Shape Popper"*. Alerta cuando se abre una shell dentro de un contenedor de imagen `shape-*`.

- No exige terminal interactiva, así que también detecta `kubectl exec <pod> -- sh -c '…'`.
- Ignora la shell que es el **proceso principal** del contenedor (`proc.vpid != 1`), como el script del generador de tráfico. Así no hay falsos positivos sin recurrir a una lista de excepciones por nombre, que un atacante podría imitar.

**Prueba** ([`scripts/test-falco`](../scripts/test-falco.sh)) sobre un pod de la versión activa:

| Acción sospechosa | Regla que la detectó | Tipo |
|---|---|---|
| `kubectl exec <pod> -- sh -c 'id; hostname'` | Shell en contenedor de Shape Popper | Propia |
| `kubectl exec <pod> -- find / -name id_rsa` | Search Private Keys or Passwords (MITRE T1552.001) | Estándar de Falco |

Las alertas guardadas en [`falco-event.log`](falco-event.log) incluyen el pod, el namespace, la imagen, el comando y el UID del proceso.

> **Nota:** la regla estándar *Terminal shell in container* exige una terminal interactiva (TTY). El entorno automatizado donde se generaron los reportes no tiene TTY, así que no pudo dispararla. Si `test-falco` se ejecuta desde una terminal interactiva, abre además una shell real (`kubectl exec -it … -- sh`), y esa regla también queda registrada.
