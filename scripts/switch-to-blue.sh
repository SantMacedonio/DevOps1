#!/usr/bin/env bash
set -e

echo "=========================================="
echo "  Rolling Back Traffic to Blue (v1.0)"
echo "=========================================="

# Patch Service selector to blue
echo "[1/1] Switching Service traffic selector to 'version: blue'..."
kubectl patch service shape-game-service -p '{"spec":{"selector":{"app":"shape-game","version":"blue"}}}'

echo ""
echo "[✔] SUCCESS: Rollback to Blue Complete!"
echo "    - Active Version: BLUE (v1.0)"
echo ""
echo "--- Active Endpoints ---"
kubectl get pods,services -l app=shape-game
