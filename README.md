# Shape Popper: Despliegue Blue/Green en Kubernetes

Juego web incremental / clicker utilizando una estrategia de **despliegue Blue/Green** en **Kubernetes (Minikube)**, empaquetado con **Docker** y con persistencia de estado respaldada por **Redis**.

Participantes: Santiago Aurrecochea

---

## Descripción General

El proyecto desacopla completamente el frontend y la lógica de juego (pods sin estado) de la base de datos (Redis con almacenamiento persistente). Esto permite actualizar la aplicación entre versiones mayores o realizar rollbacks instantáneos sin interrumpir la partida ni perder el progreso del jugador.

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
- **Docker Desktop** (en ejecución).
- **Minikube** y **kubectl** instalados.

1. **Iniciar Minikube:**
   ```bash
   minikube start
   ```

2. **Compilar y Desplegar (Windows PowerShell):**
   ```powershell
   # 1. Compilar imágenes Docker y cargarlas a Minikube
   .\scripts\build.ps1

   # 2. Desplegar Redis y la versión Blue inicial
   .\scripts\deploy.ps1

   # 3. Abrir el juego en el navegador
   minikube service shape-game-service
   ```

   *(En Linux / macOS con Bash: usar `./scripts/build.sh`, `./scripts/deploy.sh` y el mismo comando de Minikube).*

3. **Cambiar a la versión Green:**
   ```powershell
   .\scripts\switch-to-green.ps1
   ```
   *Al refrescar la página, la interfaz cambia al tema verde y desbloquea el Prestigio sin perder tus puntos acumulados.*

4. **Rollback a Blue (si fuera necesario):**
   ```powershell
   .\scripts\switch-to-blue.ps1
   ```

---