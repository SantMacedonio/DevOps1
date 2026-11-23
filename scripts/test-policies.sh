#!/usr/bin/env bash
# Valida las políticas de Kyverno intentando desplegar los manifiestos de
# k8s/security/tests/. Los "NO CONFORME" deben ser rechazados y el conforme
# aceptado. Se usa --dry-run=server: pasa por el webhook de Kyverno igual que
# un apply real, pero no crea nada en el cluster.
# Resultado: reports/kyverno-validation.txt
set -uo pipefail
cd "$(dirname "$0")/.."

OUT=reports/kyverno-validation.txt
mkdir -p reports
FAILED=0

{
    echo "Validación de políticas Kyverno"
    echo "Fecha:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Kyverno: $(kubectl get deploy -n kyverno kyverno-admission-controller -o jsonpath='{.spec.template.spec.containers[0].image}')"
    echo ""
    echo "Políticas activas:"
    kubectl get validatingpolicies
    echo ""
} > "$OUT"

for f in k8s/security/tests/*.yaml; do
    name=$(basename "$f")
    if [[ "$name" == *compliant* ]]; then expected="ACEPTADO"; else expected="RECHAZADO"; fi

    output=$(kubectl apply --dry-run=server -f "$f" 2>&1)
    if echo "$output" | grep -q "denied the request"; then result="RECHAZADO"; else result="ACEPTADO"; fi
    if [ "$result" == "$expected" ]; then status="OK"; else status="FALLO"; FAILED=1; fi

    {
        echo "------------------------------------------------------------"
        echo "Manifiesto: $f"
        echo "Esperado:   $expected   Resultado: $result   [$status]"
        echo "\$ kubectl apply --dry-run=server -f $f"
        echo "$output"
    } >> "$OUT"
    printf "%-35s esperado=%-9s resultado=%-9s [%s]\n" "$name" "$expected" "$result" "$status"
done

echo ""
if [ $FAILED -eq 0 ]; then
    echo "[OK] All policies behave as expected -> $OUT"
else
    echo "[X] Some policies did not behave as expected -> $OUT"
    exit 1
fi
