#!/usr/bin/env bash
# Analiza la calidad de las imágenes:
#   - Trivy: vulnerabilidades (binario local o contenedor aquasec/trivy)
#   - Dive : eficiencia y capas (binario local o contenedor wagoodman/dive)
#   - docker history / inspect: tamaño y cantidad de capas
# Los resultados se guardan en reports/scans/. Ejecutar antes: ./scripts/build.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TRIVY_VERSION=0.76.1
DIVE_VERSION=v0.13.1
IMAGES=("shape-game:v1" "shape-game:v2" "shape-redis:1.0.0")
OUT=reports/scans
mkdir -p "$OUT"
export MSYS_NO_PATHCONV=1   # Git Bash en Windows: no convertir rutas de -v

run_trivy() {
    if command -v trivy &> /dev/null; then
        trivy image --quiet --scanners vuln "$@"
    else
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:${TRIVY_VERSION} image --quiet --scanners vuln "$@"
    fi
}

run_dive() {
    if command -v dive &> /dev/null; then
        CI=true dive --ci-config .dive-ci "$1"
    else
        docker run --rm -e CI=true -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$PWD/.dive-ci:/.dive-ci:ro" wagoodman/dive:${DIVE_VERSION} --ci-config /.dive-ci "$1"
    fi
}

strip_ansi() { sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'; }

SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

for IMG in "${IMAGES[@]}"; do
    NAME="${IMG//[:\/]/_}"
    echo "=========================================="
    echo "  Analyzing $IMG"
    echo "=========================================="

    SIZE=$(docker images --format '{{.Size}}' "$IMG" | head -1)
    CONTENT=$(docker image inspect "$IMG" --format '{{.Size}}')
    LAYERS=$(docker image inspect "$IMG" --format '{{len .RootFS.Layers}}')
    docker history --format 'table {{.Size}}\t{{.CreatedBy}}' "$IMG" > "$OUT/layers-$NAME.txt"

    echo "[1/2] Trivy..."
    run_trivy --format table "$IMG" > "$OUT/trivy-$NAME.txt"
    VULNS=$(grep -E '^Total:' "$OUT/trivy-$NAME.txt" | sed 's/ (UNKNOWN.*//' | paste -sd ',' -)

    echo "[2/2] Dive..."
    run_dive "$IMG" 2>&1 | strip_ansi > "$OUT/dive-$NAME.txt"
    EFF=$(grep -E 'efficiency:' "$OUT/dive-$NAME.txt" | awk '{print $2" "$3}')
    WASTED=$(grep -E 'wastedBytes:' "$OUT/dive-$NAME.txt" | sed 's/^ *wastedBytes: //')
    RESULT=$(grep -E '^Result:' "$OUT/dive-$NAME.txt")

    {
        echo "$IMG"
        echo "  size (disk)      : $SIZE"
        echo "  size (content)   : $((CONTENT / 1024 / 1024)) MB"
        echo "  filesystem layers: $LAYERS"
        echo "  trivy (OS / npm) : ${VULNS:-0 (clean)}"
        echo "  dive efficiency  : $EFF"
        echo "  dive wasted      : $WASTED"
        echo "  dive $RESULT"
        echo ""
    } | tee -a "$SUMMARY"
done

echo "[OK] Reports saved in $OUT/"
