#!/usr/bin/env bash

echo "=========================================="
echo "  Cleaning Up Kubernetes Resources"
echo "=========================================="

kubectl delete -f k8s/green-deployment.yaml --ignore-not-found=true
kubectl delete -f k8s/blue-deployment.yaml --ignore-not-found=true
kubectl delete -f k8s/service.yaml --ignore-not-found=true
kubectl delete -f k8s/redis.yaml --ignore-not-found=true

echo ""
echo "[✔] SUCCESS: All resources removed from Kubernetes."
