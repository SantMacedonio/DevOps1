#!/usr/bin/env bash
# Simula jugadores para poblar el dashboard de Grafana.
# Uso: ./scripts/generate-traffic.sh [segundos=300] [jugadores=8]
#
# El tráfico se genera con un Job DENTRO del cluster (k8s/loadgen/), para que
# pase por el Service y se reparta entre los pods. Un "kubectl port-forward"
# se fijaría a un único pod y no seguiría el switch Blue -> Green.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION=${1:-300}
PLAYERS=${2:-8}

echo "=========================================="
echo "  Generating traffic: ${DURATION}s, $PLAYERS players"
echo "=========================================="

kubectl create configmap loadgen-script --from-file=loadgen.sh=k8s/loadgen/loadgen.sh \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job loadgen --ignore-not-found=true --wait=true
sed -e "s/__DURATION__/$DURATION/" -e "s/__PLAYERS__/$PLAYERS/" k8s/loadgen/job.yaml | kubectl apply -f -

kubectl wait --for=condition=Ready pod -l job-name=loadgen --timeout=120s
echo "[*] Following load generator logs (Ctrl+C stops following; the Job keeps running)..."
kubectl logs -f job/loadgen
