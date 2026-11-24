#!/usr/bin/env bash
# Detiene Jenkins. Con "--purge" borra también sus datos (volumen) y sus
# permisos en Kubernetes.
set -uo pipefail
cd "$(dirname "$0")/.."
docker rm -f shape-jenkins > /dev/null 2>&1 && echo "[OK] Jenkins stopped"
if [ "${1:-}" == "--purge" ]; then
    docker volume rm shape-jenkins-home > /dev/null 2>&1 && echo "[OK] Jenkins data removed"
    kubectl delete -f k8s/jenkins/rbac.yaml --ignore-not-found=true > /dev/null 2>&1 || true
    rm -rf .jenkins
    echo "[OK] Jenkins permissions and kubeconfig removed"
fi
