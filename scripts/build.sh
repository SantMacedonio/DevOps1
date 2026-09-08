#!/usr/bin/env bash
set -e

echo "=========================================="
echo "  Building Shape Popper Game Docker Images"
echo "=========================================="

# Bind to Minikube's Docker daemon if available
if command -v minikube &> /dev/null; then
    echo "[1/3] Configuring Docker environment for Minikube..."
    eval $(minikube -p minikube docker-env 2>/dev/null || true)
fi

# Build Blue Image (v1.0)
echo "[2/3] Building Blue (v1.0) Image: shape-game:v1 ..."
docker build --build-arg APP_VERSION=v1.0.0 --build-arg APP_COLOR=blue -t shape-game:v1 .

# Build Green Image (v2.0)
echo "[3/3] Building Green (v2.0) Image: shape-game:v2 ..."
docker build --build-arg APP_VERSION=v2.0.0 --build-arg APP_COLOR=green -t shape-game:v2 .

echo ""
echo "[✔] SUCCESS: Both Docker images built successfully!"
echo "    - shape-game:v1 (Blue Edition)"
echo "    - shape-game:v2 (Green Edition)"
