#!/usr/bin/env bash
# Despliega Prometheus + Grafana en el namespace "monitoring".
# El dashboard se carga desde grafana/dashboard.json (única fuente de verdad).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=========================================="
echo "  Deploying Monitoring (Prometheus + Grafana)"
echo "=========================================="

echo "[1/4] Namespace..."
kubectl apply -f k8s/monitoring/namespace.yaml

echo "[2/4] Grafana admin secret & dashboard ConfigMap..."
# Contraseña aleatoria, generada una sola vez (no se guarda en el repositorio)
if ! kubectl get secret grafana-admin -n monitoring &> /dev/null; then
    PASS=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
    kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-password="$PASS"
fi
DASH_RESULT=$(kubectl create configmap grafana-dashboard -n monitoring \
    --from-file=dashboard.json=grafana/dashboard.json \
    --dry-run=client -o yaml | kubectl apply -f -)
echo "$DASH_RESULT"

echo "[3/4] Prometheus..."
kubectl apply -f k8s/monitoring/prometheus.yaml
kubectl rollout status deployment/prometheus -n monitoring --timeout=180s
# Recarga la configuración si el ConfigMap cambió (sin reiniciar el pod)
kubectl exec -n monitoring deploy/prometheus -- wget -qO- --post-data='' http://localhost:9090/-/reload > /dev/null 2>&1 || true

echo "[4/4] Grafana..."
kubectl apply -f k8s/monitoring/grafana.yaml
# Si el dashboard cambió, reiniciar Grafana para que lo cargue al instante
# (seguro: Grafana no guarda estado propio, todo se reprovisiona al iniciar)
if [[ "$DASH_RESULT" == *configured* ]]; then
    kubectl rollout restart deployment/grafana -n monitoring
fi
kubectl rollout status deployment/grafana -n monitoring --timeout=180s

PASS=$(kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)
echo ""
echo "[OK] SUCCESS: monitoring stack is running"
kubectl get pods,svc -n monitoring
echo ""
echo "[->] Prometheus: minikube service prometheus -n monitoring"
echo "[->] Grafana:    minikube service grafana -n monitoring"
echo "     user: admin   password: $PASS   (anonymous read-only access is enabled)"
