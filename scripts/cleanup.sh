#!/usr/bin/env bash
# Borra todo lo que el proyecto creó en Kubernetes.
# Uso: ./scripts/cleanup.sh [--all]
#   sin opciones: app (prod y dev, con los datos de Redis), generador de tráfico,
#                 monitoreo, políticas, Kyverno y Falco
#   --all:        además Jenkins (contenedor, datos y permisos en Kubernetes)
#                 y el addon de Ingress de minikube
# minikube y las imágenes Docker no se borran. Para eso: minikube delete.
cd "$(dirname "$0")/.."

ALL=false
case "${1:-}" in
    "") ;;
    --all) ALL=true ;;
    *) echo "Uso: $0 [--all]"; exit 1 ;;
esac

echo "=========================================="
echo "  Cleaning Up Kubernetes Resources"
echo "=========================================="

# App (releases de Helm). El PVC de Redis tiene "helm.sh/resource-policy: keep"
# (Helm no lo borra al desinstalar), así que se elimina explícitamente.
helm uninstall shape-game -n default --ignore-not-found
helm uninstall shape-game-dev -n shape-dev --ignore-not-found
kubectl delete pvc -n default -l app.kubernetes.io/instance=shape-game --ignore-not-found=true
kubectl delete namespace shape-dev --ignore-not-found=true
kubectl delete job loadgen --ignore-not-found=true
kubectl delete configmap loadgen-script --ignore-not-found=true
# Monitoreo: el namespace incluye Prometheus, Grafana, Secret y ConfigMaps
kubectl delete -f k8s/monitoring/prometheus.yaml --ignore-not-found=true
kubectl delete namespace monitoring --ignore-not-found=true
# Seguridad: primero las políticas, después Kyverno (quita sus webhooks) y Falco
kubectl delete -f k8s/security/policies/ --ignore-not-found=true
kubectl delete -f k8s/security/exceptions/ --ignore-not-found=true 2> /dev/null
helm uninstall kyverno -n kyverno --ignore-not-found
helm uninstall falco -n falco --ignore-not-found
kubectl delete namespace kyverno falco --ignore-not-found=true

if $ALL; then
    echo ""
    echo "[--all] Jenkins y addon de Ingress..."
    bash scripts/jenkins-down.sh --purge
    minikube addons disable ingress
fi

echo ""
echo "[OK] SUCCESS: All resources removed from Kubernetes."
$ALL || echo "     Jenkins sigue igual. Para borrarlo también: $0 --all"
