#!/usr/bin/env bash
# Construye las imágenes Docker del proyecto y las carga en Minikube.
#   - shape-game:v1      (Blue,  v1.0.0)
#   - shape-game:v2      (Green, v2.0.0)
#   - shape-redis:1.0.1  (Redis con configuración propia, no root)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=========================================="
echo "  Building Shape Popper Docker Images"
echo "=========================================="

echo "[1/3] Building Blue (v1.0) image: shape-game:v1 ..."
docker build --pull --no-cache --build-arg APP_VERSION=v1.0.0 --build-arg APP_COLOR=blue -t shape-game:v1 .

echo "[2/3] Building Green (v2.0) image: shape-game:v2 ..."
docker build --pull --no-cache --build-arg APP_VERSION=v2.0.0 --build-arg APP_COLOR=green -t shape-game:v2 .

echo "[3/3] Building Redis image: shape-redis:1.0.1 ..."
docker build --pull --no-cache -t shape-redis:1.0.1 ./redis

# Cargar las imágenes en Minikube (funciona con cualquier driver / runtime)
if command -v minikube &> /dev/null && minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
    echo ""
    echo "[*] Loading images into Minikube..."
    minikube image load shape-game:v1
    minikube image load shape-game:v2
    minikube image load shape-redis:1.0.1
    echo "[OK] Images available inside Minikube"
else
    echo ""
    echo "[!] Minikube is not running: images were built only in the local Docker daemon."
    echo "    Run 'minikube start' and execute this script again before deploying."
fi

echo ""
echo "[OK] SUCCESS: images built"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E 'REPOSITORY|shape-'
