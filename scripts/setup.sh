#!/usr/bin/env bash
# Inicializa TODO el proyecto, en orden. Se puede volver a ejecutar: cada paso
# usa "helm upgrade --install" / "kubectl apply", que actualizan lo existente.
#   1. Verifica las herramientas (docker, minikube, kubectl, helm)
#   2. minikube (lo inicia si no está corriendo) + addon de Ingress (ingress-nginx)
#   3. Operadores de seguridad: Kyverno (+ 4 políticas) y Falco
#   4. Imágenes Docker (build sin caché y carga en minikube)
#   5. App con Helm: prod (y dev con --with-dev)
#   6. Monitoreo: Prometheus + Grafana (con el dashboard)
#   7. Jenkins (con --with-jenkins)
# Uso: ./scripts/setup.sh [--with-dev] [--with-jenkins] [--all]
#   --all = --with-dev --with-jenkins
# Después: ./scripts/generate-traffic.sh para poblar el dashboard.
# Ojo: vuelve prod al estado inicial (blue = shape-game:v1 activo, green = v2).
set -euo pipefail
cd "$(dirname "$0")/.."

WITH_DEV=false
WITH_JENKINS=false
for arg in "$@"; do
    case $arg in
        --with-dev)     WITH_DEV=true ;;
        --with-jenkins) WITH_JENKINS=true ;;
        --all)          WITH_DEV=true; WITH_JENKINS=true ;;
        *) echo "Uso: $0 [--with-dev] [--with-jenkins] [--all]"; exit 1 ;;
    esac
done
# Recursos de minikube si hay que crearlo (se ignoran si ya existe)
MINIKUBE_MEMORY=${MINIKUBE_MEMORY:-4096}
MINIKUBE_CPUS=${MINIKUBE_CPUS:-2}
START=$(date +%s)

step() {
    echo ""
    echo "############################################################"
    echo "#  $*"
    echo "############################################################"
}

step "[1/7] Herramientas"
for tool in docker minikube kubectl helm; do
    command -v "$tool" > /dev/null || { echo "[X] Falta '$tool' (ver Prerrequisitos en el README)"; exit 1; }
done
docker info > /dev/null 2>&1 || { echo "[X] Docker no responde: iniciá Docker Desktop"; exit 1; }
echo "[OK] docker, minikube, kubectl y helm disponibles"

step "[2/7] minikube + Ingress"
if minikube status --format '{{.APIServer}}' 2> /dev/null | grep -q Running; then
    echo "minikube ya está corriendo"
else
    minikube start --memory="$MINIKUBE_MEMORY" --cpus="$MINIKUBE_CPUS"
fi
minikube addons enable ingress

step "[3/7] Operadores de seguridad: Kyverno + Falco"
bash scripts/install-security.sh

step "[4/7] Imágenes Docker"
bash scripts/build.sh

step "[5/7] App con Helm"
bash scripts/deploy.sh prod
if $WITH_DEV; then bash scripts/deploy.sh dev; else echo "dev omitido (usar --with-dev)"; fi

step "[6/7] Monitoreo: Prometheus + Grafana"
bash scripts/deploy-monitoring.sh

step "[7/7] Jenkins"
if $WITH_JENKINS; then bash scripts/jenkins-up.sh; else echo "Jenkins omitido (usar --with-jenkins)"; fi

step "Listo en $(( ($(date +%s) - START) / 60 )) min $(( ($(date +%s) - START) % 60 )) s"
kubectl get pods -A -l 'app.kubernetes.io/name in (shape-game,prometheus,grafana)' 2> /dev/null || true
cat <<EOF

Próximos pasos:
  ./scripts/generate-traffic.sh            # jugadores simulados para poblar el dashboard
  minikube service shape-game              # abrir el juego (prod)
  minikube service grafana -n monitoring   # abrir Grafana (dashboard "Shape Popper")
  minikube service prometheus -n monitoring
  ./scripts/test-policies.sh               # evidencia de Kyverno -> reports/kyverno-validation.log
  ./scripts/test-falco.sh                  # evidencia de Falco   -> reports/falco-event.log
  ./scripts/security-scan.sh               # npm audit, Snyk, Semgrep, Trivy, KubeLinter -> reports/
EOF
$WITH_JENKINS && echo "  Jenkins: http://localhost:8080 (usuario admin, contraseña en .env.jenkins)"
exit 0
