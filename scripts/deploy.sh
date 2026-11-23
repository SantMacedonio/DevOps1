#!/usr/bin/env bash
# Despliega Shape Popper (app Blue/Green + Redis) con la Helm Chart.
# Uso: ./scripts/deploy.sh [prod|dev]   (por defecto: prod)
#   prod -> release "shape-game"     en el namespace "default"   (values-prod.yaml)
#   dev  -> release "shape-game-dev" en el namespace "shape-dev" (values-dev.yaml)
set -euo pipefail
cd "$(dirname "$0")/.."

ENV=${1:-prod}
case $ENV in
    prod) RELEASE=shape-game;     NS=default ;;
    dev)  RELEASE=shape-game-dev; NS=shape-dev ;;
    *) echo "Uso: $0 [prod|dev]"; exit 1 ;;
esac

echo "=========================================="
echo "  Deploying Shape Popper with Helm ($ENV)"
echo "=========================================="

echo "[1/3] helm upgrade --install $RELEASE (namespace $NS)..."
# "upgrade --install": instala si no existe y actualiza si ya existe
helm upgrade --install "$RELEASE" ./helm-chart \
    -f "helm-chart/values-$ENV.yaml" \
    -n "$NS" --create-namespace \
    --wait --timeout 5m

echo "[2/3] Pods:"
kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE"

echo "[3/3] helm test (service reachable + Redis connected)..."
helm test "$RELEASE" -n "$NS" --logs

echo ""
echo "[OK] SUCCESS: $RELEASE deployed in namespace $NS"
helm status "$RELEASE" -n "$NS" --show-resources | sed -n '/NOTES:/,$p'
