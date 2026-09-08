#!/usr/bin/env bash
set -e

echo "=========================================="
echo "  Deploying Game Infrastructure to Minikube"
echo "=========================================="

# 1. Deploy Redis
echo "[1/3] Deploying Redis Database & Persistent Volume..."
kubectl apply -f k8s/redis.yaml
kubectl rollout status deployment/redis --timeout=90s

# 2. Deploy Blue (v1.0)
echo "[2/3] Deploying Blue Application (v1.0)..."
kubectl apply -f k8s/blue-deployment.yaml
kubectl rollout status deployment/shape-game-blue --timeout=90s

# 3. Deploy Kubernetes Service
echo "[3/3] Configuring Blue/Green Service Router..."
kubectl apply -f k8s/service.yaml

echo ""
echo "[✔] SUCCESS: Blue (v1.0) is active and running!"
echo ""
echo "--- Cluster Status ---"
kubectl get pods,services -l app=shape-game

echo ""
echo "[➔] To open the game in your browser, run:"
echo "    minikube service shape-game-service"
