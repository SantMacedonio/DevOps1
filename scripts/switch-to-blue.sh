#!/usr/bin/env bash
# Switch Blue/Green: el Service pasa a enviar el tráfico a la versión BLUE.
# Es un "helm upgrade" que solo cambia app.activeColor (el resto de los valores
# de la release se conserva). Para deshacerlo: switch-to-green o "helm rollback".
# Uso: ./scripts/switch-to-blue.sh [prod|dev]   (por defecto: prod)
set -euo pipefail
cd "$(dirname "$0")/.."

ENV=${1:-prod}
case $ENV in
    prod) RELEASE=shape-game;     NS=default ;;
    dev)  RELEASE=shape-game-dev; NS=shape-dev ;;
    *) echo "Uso: $0 [prod|dev]"; exit 1 ;;
esac

echo "=========================================="
echo "  Blue/Green switch -> BLUE ($ENV)"
echo "=========================================="

echo "[1/3] helm upgrade $RELEASE --set app.activeColor=blue..."
helm upgrade "$RELEASE" ./helm-chart -n "$NS"     --reset-then-reuse-values --set app.activeColor=blue     --wait --timeout 5m

echo "[2/3] Verifying (helm test)..."
helm test "$RELEASE" -n "$NS" --logs

echo "[3/3] Release history:"
helm history "$RELEASE" -n "$NS" --max 5

echo ""
echo "[OK] SUCCESS: traffic now goes to BLUE"
echo "     Player progress is preserved in Redis."
echo "     Undo: ./scripts/switch-to-green.sh $ENV   or   helm rollback $RELEASE -n $NS"
