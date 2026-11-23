#!/usr/bin/env bash
# Ejecuta acciones sospechosas dentro de un pod de la app y guarda las alertas
# que registra Falco en reports/falco-event.log (una alerta JSON por línea).
#   1. Abre una shell (regla propia "Shell en contenedor de Shape Popper")
#   2. Busca claves privadas (regla estándar "Search Private Keys or Passwords")
#   3. Si la terminal es interactiva, abre una shell con TTY
#      (regla estándar "Terminal shell in container")
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1   # Git Bash: no convertir "/" en rutas de Windows

OUT=reports/falco-event.log
mkdir -p reports

# Pod de la versión activa (la que tiene el Service en su selector)
COLOR=$(kubectl get svc shape-game -o jsonpath='{.spec.selector.version}')
POD=$(kubectl get pod -l app=shape-game,version="$COLOR" -o jsonpath='{.items[0].metadata.name}')
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "=========================================="
echo "  Falco test on pod $POD"
echo "=========================================="

echo "[1/3] Opening a shell inside the container..."
kubectl exec "$POD" -- sh -c 'id; hostname' || true

echo "[2/3] Searching for private keys..."
kubectl exec "$POD" -- find / -name id_rsa 2> /dev/null || true

if [ -t 0 ] && [ -t 1 ]; then
    echo "[3/3] Interactive shell with TTY (type 'exit' to continue)..."
    kubectl exec -it "$POD" -- sh || true
else
    echo "[3/3] Skipped: this terminal is not interactive (no TTY)."
    echo "      To trigger 'Terminal shell in container' run: kubectl exec -it $POD -- sh"
fi

echo "[*] Waiting for Falco to flush the events..."
sleep 5
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --since-time="$START" --tail=-1 \
    | grep '^{' | grep "\"k8s.pod.name\":\"$POD\"" > "$OUT" || true

COUNT=$(wc -l < "$OUT" | tr -d ' ')
echo ""
if [ "$COUNT" -gt 0 ]; then
    echo "[OK] Falco registered $COUNT event(s) -> $OUT"
    grep -o '"rule":"[^"]*"' "$OUT" | sort | uniq -c
else
    echo "[X] No Falco events found for $POD"
    exit 1
fi
