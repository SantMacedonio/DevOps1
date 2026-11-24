# Reporte de seguridad (DevSecOps)

Fecha: 2026-11-24 · Cluster: minikube (Kubernetes 1.37, kernel 5.15 WSL2)

| Área | Herramienta | Evidencia | Resultado |
|---|---|---|---|
| Dependencias | npm audit (npm 11.12) | [`npm-audit.txt`](npm-audit.txt) | **0 vulnerabilidades** |
| Dependencias | Snyk CLI 1.1309.0 | [`snyk-report.txt`](snyk-report.txt) | **0 vulnerabilidades** (80 dependencias). Se corrigió 1 HIGH nueva en `ioredis` (5.11.1 → 6.0.0) |
| Código (SAST) | Semgrep 1.186.0: 209 reglas oficiales + **3 reglas propias** | [`semgrep-report.txt`](semgrep-report.txt) | **1 hallazgo (WARNING), justificado**. Las 3 reglas propias pasan sus casos de prueba. Además, 6 correcciones por revisión manual |
| Imágenes | Trivy 0.76.1 | [`trivyreport.txt`](trivyreport.txt) | Imágenes propias: **0 vulnerabilidades, 0 secretos** (se corrigieron 10 nuevas de OpenSSL en Redis). Terceros: 22 HIGH documentados |
| Políticas K8s | Kyverno 1.20.0 | [`kyverno-validation.log`](kyverno-validation.log) | **4 políticas** en modo **Deny**: los 4 manifiestos no conformes se rechazan (cada uno por su política) y el conforme se acepta |
| Manifiestos K8s | KubeLinter 0.8.3 | [`kubelinter.txt`](kubelinter.txt) | **0 errores** (se corrigieron 2) |
| Runtime | Falco 0.45.2 | [`falco-event.log`](falco-event.log) | **Búsqueda de claves privadas** (y shell) en un pod **detectadas** |

Para regenerar todo:

```powershell
.\scripts\security-scan.ps1     # npm audit, Snyk, Semgrep, Trivy, KubeLinter   (./scripts/security-scan.sh)
.\scripts\test-policies.ps1     # Kyverno                                       (./scripts/test-policies.sh)
.\scripts\test-falco.ps1        # Falco                                         (./scripts/test-falco.sh)
```

---

## 1. Seguridad en el código

### npm audit

`npm audit` no encuentra vulnerabilidades en las 4 dependencias directas (`express`, `ioredis`, `helmet` y `@prometheus-io/client`) ni en las transitivas. Ya en el punto 1 se habían actualizado `express`, para corregir `body-parser` y `proxy-addr`, y se había quitado `uuid`, que no se usaba.

### Snyk

Snyk analiza las mismas dependencias contra su propia base de vulnerabilidades, que suele detectar problemas antes que la de npm y propone cómo corregirlos. Se ejecuta en dos lugares:

- **En el pipeline de Jenkins** (etapa 2), con `--severity-threshold=critical`: si encuentra una vulnerabilidad **crítica**, el pipeline se detiene.
- **En `scripts/security-scan`**, que guarda el reporte completo en [`snyk-report.txt`](snyk-report.txt). Al final del reporte, [`ci/snyk-summary.js`](../ci/snyk-summary.js) lista cada vulnerabilidad por severidad con la **corrección propuesta**: a qué versión subir la dependencia directa, o qué hacer si no hay versión corregida.

Resultado actual: **0 vulnerabilidades en 80 dependencias**. Hubo dos casos durante el proyecto:

| Caso | Severidad | Qué pasó | Corrección |
|---|---|---|---|
| `ioredis@5.11.1`: *Uncontrolled Recursion* (SNYK-JS-IOREDIS-19963957) | HIGH | Apareció al repetir el análisis el 2026-11-24 (no existía en el primero). No es crítica, así que no detenía el pipeline, pero tenía corrección | Snyk propuso actualizar a `ioredis@6.0.0` (cambio de versión mayor). Se eligió la 6.0.0 y no la 6.1.0, que tenía un día de publicada. Se verificó con los 26 tests y con una prueba de integración contra un Redis real (guardar y leer partidas, comprar mejoras, jugadores activos, métricas): todo funciona sin cambios en el código |
| `node-serialize@0.0.4`: *Arbitrary Code Execution* (npm:node-serialize:20170208) | **CRITICAL** | Se agregó **a propósito** en una rama de prueba, para demostrar el corte del pipeline. Jenkins se detuvo en la etapa de Snyk y no construyó ni desplegó nada ([log del build #2](jenkins/build-2-detenido-por-snyk.txt)) | No existe versión corregida: la corrección es **eliminar el paquete** o reemplazarlo. Para serializar datos alcanza con `JSON.stringify`/`JSON.parse`, que no ejecutan código. La rama de prueba se borró |

> **Ojo con las escalas:** Snyk usa su propia clasificación. Para la demo primero se pensó en `minimist@0.0.8`, que otras bases consideran grave, pero Snyk lo califica como baja y media, así que no habría detenido el pipeline. Por eso se verificó con Snyk antes de elegir el paquete.

### Semgrep

Se ejecuta con dos tipos de reglas: **212 reglas** (209 oficiales y 3 propias) sobre 92 archivos (JS, HTML, Dockerfile, YAML y scripts).

**1. Conjuntos oficiales:** `p/javascript`, `p/nodejs`, `p/expressjs`, `p/xss`, `p/owasp-top-ten`, `p/security-audit`, `p/secrets`, `p/dockerfile` y `p/kubernetes`.

**2. Reglas propias para JavaScript/Express** ([`semgrep/shape-popper.yaml`](../semgrep/shape-popper.yaml)). Protegen decisiones de seguridad concretas de este proyecto, para que un cambio futuro no las deshaga sin que nadie lo note:

| Regla | Severidad | Qué detecta | CWE / OWASP |
|---|---|---|---|
| `express-sin-helmet` | ERROR | Una app de Express creada sin `app.use(helmet(...))`: sin CSP ni headers de seguridad | CWE-693 · A05:2021 |
| `express-json-sin-limite` | ERROR | `express.json()` sin `limit`: cuerpos JSON enormes agotan la memoria (DoS) | CWE-400 · A04:2021 |
| `innerhtml-con-contenido-dinamico` | WARNING | HTML armado dinámicamente asignado a `innerHTML` (posible XSS) | CWE-79 · A03:2021 |

Las reglas tienen sus propios **casos de prueba** ([`semgrep/shape-popper.js`](../semgrep/shape-popper.js)): código inseguro que cada regla debe detectar y código seguro que no debe marcar. `semgrep --test semgrep/` da **3/3: All tests passed**, y el resultado queda en la sección 2 del reporte. Ese archivo tiene código inseguro a propósito, así que los análisis del proyecto lo excluyen.

**Resultado sobre el código: 1 hallazgo, justificado.**

| Hallazgo | Justificación |
|---|---|
| `innerhtml-con-contenido-dinamico` en [`src/public/app.js`](../src/public/app.js) (`els.upgradesContainer.innerHTML = html`), severidad WARNING | Es la tienda de mejoras. El HTML se arma con un *template* en el que **cada valor interpolado pasa por `escapeHtml()`** (nombre, descripción y clave de la mejora), una corrección que ya había salido de la revisión manual (punto 5 de la tabla de abajo). Además, esos datos vienen del propio servidor, no de otros jugadores, y la CSP prohíbe scripts inline, que es una segunda barrera. Se mantiene como WARNING visible, que no detiene el pipeline (el corte de Jenkins es solo por ERROR), para que cualquier cambio en esa función se revise con cuidado |

> **Detalle importante:** por defecto Semgrep analiza **solo los archivos con commit en git**. Como gran parte del proyecto todavía no tenía commit, el primer análisis dejó afuera archivos como `src/metrics.js`. Se usa `--no-git-ignore` para analizarlo todo.

Que Semgrep no marque nada no significa que el código no tenga problemas. Las reglas de la comunidad buscan patrones conocidos. Por eso se hizo además una **revisión manual**, que encontró y corrigió lo siguiente. Dos de esas correcciones (helmet y el límite del body) quedaron protegidas después con las reglas propias:

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

`shape-game:v1`, `shape-game:v2` y `shape-redis:1.0.1` no tienen **ninguna vulnerabilidad** (de ninguna severidad) **ni secretos** expuestos. Las medidas que lo permiten se describen en [`image-analysis.md`](image-analysis.md):

- La imagen final de la app no incluye npm.
- Las imágenes base usan versiones exactas y actuales.
- Se aplica `apk upgrade` para incorporar los parches de Alpine, y las imágenes se construyen **sin caché** (`--pull --no-cache`) para que ese paso realmente se ejecute.

**Caso de este análisis:** al repetirlo el 2026-11-24, `shape-redis:1.0.0` tenía **10 vulnerabilidades nuevas de OpenSSL** (6 MEDIUM, 4 LOW), publicadas después del primer análisis y ya corregidas en Alpine. El build con caché no las corregía, porque reutilizaba la capa vieja del `apk upgrade`. Se reconstruyó sin caché y con un Dockerfile multi-stage, y se publicó como `shape-redis:1.0.1`: **0 vulnerabilidades**. El detalle está en [`image-analysis.md`](image-analysis.md#capas-de-shape-redis101).

En el pipeline, Trivy además **detiene la publicación** si la imagen tiene vulnerabilidades críticas o **cualquier secreto**, porque el paquete de ghcr.io es público.

### Imágenes de terceros: HIGH documentados

Trivy también se corrió sobre las imágenes oficiales que usa el cluster. Al momento del análisis, son las **últimas versiones publicadas**, así que no hay una versión corregida para actualizar.

| Imagen | HIGH | Vulnerabilidades | Componente afectado | Mitigación / justificación |
|---|---|---|---|---|
| `prom/prometheus:v3.16.0` | 2 | CVE-2026-78661 (DoS en `x/net/html`) | Librería Go compilada en el binario | Prometheus no procesa HTML de terceros. Solo es accesible dentro del cluster o por NodePort en minikube. Se actualiza cuando salga una versión corregida. |
| `grafana/grafana:13.3.1` | 20 | CVE-2026-78661, CVE-2026-78669 (DoS en `x/net`) · CVE-2026-78667, CVE-2026-97031 (DoS en `net/http`, `crypto/tls`) · CVE-2026-111943 (`crypto/x509`, MITM) · CVE-2026-21728, CVE-2026-28377 (Tempo) | Go stdlib y librerías de plugins incluidos | La mayoría son DoS. El de `crypto/x509` afecta conexiones TLS salientes, pero Grafana solo se conecta a Prometheus por HTTP interno. Las de Tempo no aplican, porque no se usa Tempo como fuente de datos. Grafana no está expuesto a Internet. Se actualiza cuando haya parche. |
| ~~`curlimages/curl:8.23.0`~~ | ~~32~~ | krb5 y otras librerías de Alpine | — | **Resuelto:** el generador de tráfico ahora usa la imagen de la app, que ya trae `sh` y `wget` y tiene 0 vulnerabilidades. La imagen de curl dejó de usarse. |

---

## 3. Seguridad en Kubernetes

### Kyverno: 4 políticas en modo Deny

Kyverno 1.20 declara **deprecado** el tipo clásico `ClusterPolicy`. Las políticas se escribieron con la API nueva, **`ValidatingPolicy`** (`policies.kyverno.io/v1`), que usa expresiones **CEL**, el mismo lenguaje de las *ValidatingAdmissionPolicies* nativas de Kubernetes.

| # | Política | Archivo | Qué exige |
|---|---|---|---|
| 1 | `disallow-latest-tag` | [`disallow-latest-tag.yaml`](../k8s/security/policies/disallow-latest-tag.yaml) | Todas las imágenes con tag explícito (o digest) y distinto de `latest`. Contempla registries con puerto (`localhost:5000/app` sin tag se rechaza). |
| 2 | `require-requests-limits` | [`require-requests-limits.yaml`](../k8s/security/policies/require-requests-limits.yaml) | `requests` y `limits` de CPU y memoria en todos los contenedores, incluidos los initContainers. |
| 3 | `require-non-root` | [`require-non-root.yaml`](../k8s/security/policies/require-non-root.yaml) | `runAsNonRoot: true` (a nivel pod o en cada contenedor) y prohíbe `runAsUser: 0`. |
| 4 | `disallow-privilege-escalation` *(buena práctica elegida)* | [`disallow-privilege-escalation.yaml`](../k8s/security/policies/disallow-privilege-escalation.yaml) | `allowPrivilegeEscalation: false` explícito en todos los contenedores. |

**Por qué la política 4.** Con `allowPrivilegeEscalation: false`, el kernel activa *no_new_privs*: ningún proceso del contenedor puede ganar más privilegios que su padre, por ejemplo con un binario *setuid* como `sudo` o `su`. Complementa a `require-non-root`, porque aunque una imagen traiga un binario setuid, no sirve para volverse root. Es uno de los controles del perfil *restricted* de los Pod Security Standards de Kubernetes. Se exige **explícito** porque Kubernetes, si no se declara, lo deja permitido. Antes de activarla se verificó que todos los pods del proyecto ya la cumplieran (10 de 10), para que no rompiera ningún despliegue.

Kyverno genera automáticamente la misma validación para los controladores (Deployment, Job, StatefulSet, etc.). Por eso un Deployment no conforme se rechaza en el `kubectl apply`, en vez de crearse y quedarse sin pods.

**Validación** ([`kyverno-validation.log`](kyverno-validation.log)): cada manifiesto de [`k8s/security/tests/`](../k8s/security/tests/) viola **una sola** política, y hay uno conforme. Se verificó que cada rechazo lo produce únicamente la política esperada.

| Manifiesto | Esperado | Resultado | Política que lo rechaza | Mensaje de Kyverno |
|---|---|---|---|---|
| `01-latest-tag.yaml` | Rechazo | Rechazado | `disallow-latest-tag` | *Prohibido usar imágenes sin tag o con la etiqueta latest… nginxinc/nginx-unprivileged:latest* |
| `02-no-resources.yaml` (Pod) | Rechazo | Rechazado | `require-requests-limits` | *Todos los contenedores deben definir resources.requests y resources.limits… web* |
| `03-run-as-root.yaml` | Rechazo | Rechazado | `require-non-root` | *Los contenedores no pueden ejecutarse como root…* |
| `04-compliant.yaml` | Aceptación | Aceptado | — | — |
| `05-privilege-escalation.yaml` | Rechazo | Rechazado | `disallow-privilege-escalation` | *Todos los contenedores deben declarar securityContext.allowPrivilegeEscalation: false…* |

Además, todos los recursos del proyecto (app, Redis, Prometheus, Grafana y el generador de tráfico) se volvieron a desplegar con las 4 políticas activas sin ningún rechazo. Lo mismo vale para la Helm Chart, con los tres juegos de valores (`values.yaml`, `values-dev.yaml` y `values-prod.yaml`).

**Excepciones y exclusiones, con su justificación:**

- **Namespaces excluidos:** `kube-system`, `kube-public`, `kube-node-lease`, `kyverno`, `falco` e `ingress-nginx`. Los componentes del sistema y Falco necesitan privilegios. Falco corre como root porque carga un programa eBPF en el kernel para observar las llamadas al sistema. El Ingress Controller lo instala minikube (addon) sin `requests` ni `limits`, y la política lo bloqueaba.
- **`PolicyException` puntual** ([`k8s/security/exceptions/redis-chown.yaml`](../k8s/security/exceptions/redis-chown.yaml)): para la migración de permisos de Redis, que requiere un pod root una sola vez. Solo aplica a un pod llamado `redis-chown` en `default`. Se aplica antes de la migración y se borra después. Kyverno solo acepta excepciones creadas en el namespace `kyverno`, así que alguien con acceso únicamente a `default` no puede eximirse a sí mismo.
- **`failurePolicy: Fail`:** si Kyverno no responde, los pods de los namespaces controlados no se crean. Se priorizó la seguridad sobre la disponibilidad.

### KubeLinter: 0 errores

El primer análisis marcó **2 errores** (`no-anti-affinity` en blue y green). Se corrigieron con `podAntiAffinity` **preferida** (`preferredDuringScheduling…`), que reparte las réplicas en nodos distintos cuando hay más de uno. No se usó la versión obligatoria (`required…`) porque minikube tiene un solo nodo, y la segunda réplica quedaría en `Pending`.

Además, de los checks opcionales (`--add-all-built-in`) se aplicó `default-service-account`: `automountServiceAccountToken: false` en todos los pods que no usan la API de Kubernetes (todos menos Prometheus). Si alguien entra a un contenedor, no encuentra un token para hablar con el cluster.

El reporte incluye una segunda sección de **control**: KubeLinter sobre los manifiestos de prueba no conformes. Ahí marca exactamente las violaciones esperadas (`latest-tag`, `unset-cpu/memory-requirements`, `run-as-non-root`, `privilege-escalation-container`), lo que demuestra que la herramienta efectivamente analiza.

Checks opcionales que **no** se aplicaron:

| Check | Motivo |
|---|---|
| `non-isolated-pod` (NetworkPolicy) | La red por defecto de minikube no aplica NetworkPolicies, así que no tendría efecto real. En producción se agregaría una política que solo permita tráfico de la app a Redis y de Prometheus a la app. |
| `minimum-three-replicas`, `no-node-affinity` | Hay un solo nodo y recursos limitados. |
| `sorted-keys`, `required-label-owner`, `required-annotation-email`, `dnsconfig-options`, `use-namespace` | Son de estilo o convenciones organizacionales, no de seguridad. |

---

## 4. Seguridad en tiempo de ejecución (Falco)

Falco 0.45.2 (chart 9.2.2) se instaló con el driver **`modern_ebpf`**. No requiere compilar módulos del kernel y funciona sobre el kernel 5.15 de WSL2 porque tiene BTF. Los eventos se emiten en JSON.

**Prueba** ([`scripts/test-falco`](../scripts/test-falco.sh)) sobre un pod de la versión activa. El enunciado pide una acción que **no** sea abrir una shell; esa es la primera de la tabla:

| Acción sospechosa | Regla que la detectó | Tipo |
|---|---|---|
| `kubectl exec <pod> -- find / -name id_rsa` **(sin shell)** | Search Private Keys or Passwords (MITRE ATT&CK T1552.001) | Estándar de Falco |
| `kubectl exec <pod> -- sh -c 'id; hostname'` | Shell en contenedor de Shape Popper | Propia |

### Descripción del evento detectado

**Qué se hizo:** se ejecutó `find / -name id_rsa` directamente dentro de un contenedor de la app (`kubectl exec <pod> -- find …`, sin pasar por una shell). Es lo que hace un atacante que ya entró a un contenedor y busca **claves SSH privadas** (`id_rsa`) para moverse a otros sistemas.

**Qué detectó Falco:** la regla estándar *Search Private Keys or Passwords* observó, a nivel del kernel (llamada al sistema `execve`), un proceso `find` cuyos argumentos buscan nombres de archivos de credenciales. Generó una alerta de prioridad **Warning** con la técnica **T1552.001** de MITRE ATT&CK (*Unsecured Credentials: Credentials In Files*). La alerta guardada en [`falco-event.log`](falco-event.log) incluye:

- el comando completo (`find / -name id_rsa`) y el usuario (`uid=1000`, el usuario sin privilegios `node`);
- el pod, el namespace, el contenedor y la imagen (`shape-game`);
- la marca de tiempo y las etiquetas de la regla (`container`, `filesystem`, `mitre_credential_access`).

**Por qué importa:** la app nunca ejecuta `find` ni busca claves, así que esa actividad solo puede venir de una persona dentro del contenedor. Falco no la bloquea (solo observa), pero deja el registro para investigar. En producción, esta alerta se mandaría a un sistema de alertas (Slack, PagerDuty) con Falcosidekick.

### Regla propia

*"Shell en contenedor de Shape Popper"* ([`falco-values.yaml`](../k8s/security/falco-values.yaml)) alerta cuando se abre una shell dentro de un contenedor de imagen `shape-*`.

- No exige terminal interactiva, así que también detecta `kubectl exec <pod> -- sh -c '…'`.
- Ignora la shell que es el **proceso principal** del contenedor (`proc.vpid != 1`), como el script del generador de tráfico. Así no hay falsos positivos sin recurrir a una lista de excepciones por nombre, que un atacante podría imitar.

> **Nota:** la regla estándar *Terminal shell in container* exige una terminal interactiva (TTY). El entorno automatizado donde se generaron los reportes no tiene TTY, así que no pudo dispararla. Si `test-falco` se ejecuta desde una terminal interactiva, abre además una shell real (`kubectl exec -it … -- sh`), y esa regla también queda registrada.
