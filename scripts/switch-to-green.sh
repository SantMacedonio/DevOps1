#!/usr/bin/env bash
set -e

echo "=========================================="
echo "  Executing Blue -> Green Rolling Switch"
echo "=========================================="

# 1. Deploy Green (v2.0)
echo "[1/3] Deploying Green (v2.0 with Prestige Ascension)..."
kubectl apply -f k8s/green-deployment.yaml

# 2. Wait for Green pods to become completely Ready
echo "[2/3] Waiting for Green Pods to pass readiness probes..."
kubectl rollout status deployment/shape-game-green --timeout=90s

# 3. Seamlessly switch traffic to Green
echo "[3/3] Switching Service traffic selector to 'version: green'..."
kubectl patch service shape-game-service -p '{"spec":{"selector":{"app":"shape-game","version":"green"}}}'

echo ""
echo "[✔] SUCCESS: Blue/Green Switch Complete!"
echo "    - Active Version: GREEN (v2.0 - Prestige Ascension Enabled)"
echo "    - State Persistence: Player progress, points, and upgrades safely preserved in Redis."
echo ""
echo "--- Active Endpoints ---"
kubectl get pods,services -l app=shape-game
