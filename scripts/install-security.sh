#!/usr/bin/env bash
# Instala las herramientas de seguridad del cluster:
#   - Kyverno + 3 políticas (latest tag, requests/limits, no root)
#   - Falco (seguridad en tiempo de ejecución) con la regla propia de Shape Popper
# Requiere: helm, kubectl y minikube en ejecución.
set -euo pipefail
cd "$(dirname "$0")/.."

KYVERNO_CHART_VERSION=3.10.0   # Kyverno v1.20.0
FALCO_CHART_VERSION=9.2.2      # Falco 0.45.2

echo "=========================================="
echo "  Installing security tools (Kyverno + Falco)"
echo "=========================================="

echo "[1/4] Helm repositories..."
helm repo add kyverno https://kyverno.github.io/kyverno/ > /dev/null 2>&1 || true
helm repo add falcosecurity https://falcosecurity.github.io/charts > /dev/null 2>&1 || true
helm repo update kyverno falcosecurity

echo "[2/4] Kyverno $KYVERNO_CHART_VERSION..."
helm upgrade --install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" \
    -n kyverno --create-namespace -f k8s/security/kyverno-values.yaml --wait --timeout 6m

echo "[3/4] Kyverno policies..."
kubectl apply -f k8s/security/policies/
kubectl wait validatingpolicy --all --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=120s

echo "[4/4] Falco $FALCO_CHART_VERSION..."
helm upgrade --install falco falcosecurity/falco --version "$FALCO_CHART_VERSION" \
    -n falco --create-namespace -f k8s/security/falco-values.yaml --wait --timeout 6m

echo ""
echo "[OK] SUCCESS: security tools installed"
kubectl get validatingpolicies
kubectl get pods -n kyverno
kubectl get pods -n falco
echo ""
echo "[->] Validate the policies: ./scripts/test-policies.sh"
echo "[->] Test Falco:            ./scripts/test-falco.sh"
