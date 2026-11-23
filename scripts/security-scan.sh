#!/usr/bin/env bash
# Análisis de seguridad (DevSecOps). Genera en reports/:
#   npm-audit.txt   -> dependencias de Node.js con vulnerabilidades conocidas
#   semgrep.txt     -> análisis estático del código (SAST)
#   trivyreport.txt -> vulnerabilidades y secretos en las imágenes Docker
#   kubelinter.txt  -> buenas prácticas de seguridad en los manifiestos de Kubernetes
# Ejecutar antes ./scripts/build.sh (Trivy escanea las imágenes locales).
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1   # Git Bash en Windows: no convertir rutas

SEMGREP_VERSION=1.186.0
TRIVY_VERSION=0.76.1
KUBELINTER_VERSION=v0.8.3
OWN_IMAGES=("shape-game:v1" "shape-game:v2" "shape-redis:1.0.0")
THIRD_PARTY_IMAGES=("prom/prometheus:v3.16.0" "grafana/grafana:13.3.1")
mkdir -p reports

# Ruta del proyecto para montar en contenedores (formato Windows en Git Bash)
if command -v cygpath &> /dev/null; then SRC=$(cygpath -w "$PWD"); else SRC=$PWD; fi

header() {
    echo "# $1"
    echo "# Fecha: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# Comando: $2"
    echo ""
}

run_trivy() {
    if command -v trivy &> /dev/null; then
        trivy image --quiet "$@"
    else
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:${TRIVY_VERSION} image --quiet "$@"
    fi
}

echo "=========================================="
echo "  Security scan (npm audit, Semgrep, Trivy, KubeLinter)"
echo "=========================================="

# --- 1. npm audit -----------------------------------------------------------
echo "[1/4] npm audit..."
{
    header "npm audit - npm $(npm --version)" "npm audit"
    npm audit 2>&1
    echo ""
    echo "## Resumen (npm audit --json)"
    npm audit --json 2>/dev/null | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const m=JSON.parse(d).metadata;console.log("Vulnerabilidades:",JSON.stringify(m.vulnerabilities));console.log("Dependencias analizadas:",JSON.stringify(m.dependencies))})'
} > reports/npm-audit.txt

# --- 2. Semgrep ---------------------------------------------------------------
echo "[2/4] Semgrep $SEMGREP_VERSION..."
SEMGREP_CONFIGS="--config p/javascript --config p/nodejs --config p/expressjs --config p/xss --config p/owasp-top-ten --config p/security-audit --config p/secrets --config p/dockerfile --config p/kubernetes"
{
    header "Semgrep $SEMGREP_VERSION (SAST)" "semgrep scan $SEMGREP_CONFIGS --no-git-ignore"
    docker run --rm -v "$SRC:/src" -w /src semgrep/semgrep:${SEMGREP_VERSION} \
        semgrep scan $SEMGREP_CONFIGS --metrics=off --no-git-ignore \
        --exclude node_modules --exclude reports --exclude .git \
        --exclude 'k8s/security/tests' 2>&1 \
        | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | grep -vE 'Pulling|Download|Pull complete|Digest:|Status:'
} > reports/semgrep.txt

# --- 3. Trivy -----------------------------------------------------------------
echo "[3/4] Trivy..."
{
    header "Trivy (vulnerabilidades y secretos)" "trivy image --scanners vuln,secret <imagen>"
    echo "############################################################"
    echo "# PARTE 1: imágenes propias (todas las severidades)"
    echo "############################################################"
    for IMG in "${OWN_IMAGES[@]}"; do
        echo ""
        echo "==================== $IMG ===================="
        run_trivy --scanners vuln,secret --format table "$IMG" 2>&1
    done
    echo ""
    echo "############################################################"
    echo "# PARTE 2: imágenes de terceros usadas en el cluster (HIGH/CRITICAL)"
    echo "# Informativo: no se construyen en este proyecto. Ver reports/security-report.md"
    echo "############################################################"
    for IMG in "${THIRD_PARTY_IMAGES[@]}"; do
        echo ""
        echo "==================== $IMG ===================="
        docker pull -q "$IMG" > /dev/null 2>&1 || true
        run_trivy --scanners vuln --severity HIGH,CRITICAL --format table "$IMG" 2>&1
    done
} > reports/trivyreport.txt

# --- 4. KubeLinter --------------------------------------------------------------
echo "[4/4] KubeLinter..."
run_kubelinter() {
    if command -v kube-linter &> /dev/null; then
        kube-linter lint "$@"
    else
        docker run --rm -v "$SRC:/src" -w /src stackrox/kube-linter:${KUBELINTER_VERSION} lint "$@"
    fi
}
{
    header "KubeLinter $KUBELINTER_VERSION" "kube-linter lint --ignore-paths 'k8s/security/tests/**' k8s/ helm-chart/"
    echo "## 1. Manifiestos del proyecto y Helm Chart (checks por defecto)"
    run_kubelinter --ignore-paths 'k8s/security/tests/**' k8s/ helm-chart/ 2>&1
    echo ""
    echo "## 2. Control: manifiestos NO CONFORMES de prueba de Kyverno (k8s/security/tests/)"
    echo "##    Se espera que KubeLinter también los marque (demuestra que la herramienta funciona)."
    run_kubelinter k8s/security/tests/ 2>&1
} | sed -E "s#$(printf '%s' "$PWD" | sed 's/[\/&]/\\&/g')/##g; s#$(printf '%s' "$SRC" | sed 's/[\\/&]/\\&/g')\\\\##g" > reports/kubelinter.txt

echo ""
echo "[OK] Reports generated:"
for f in npm-audit semgrep trivyreport kubelinter; do
    printf "  reports/%-16s " "$f.txt"
    case $f in
        npm-audit)   grep -m1 -E "found [0-9]+ vulnerabilit" reports/npm-audit.txt ;;
        semgrep)     grep -m1 -E "Ran [0-9]+ rules" reports/semgrep.txt ;;
        trivyreport)
            OWN=$(awk '/PARTE 1/,/PARTE 2/' reports/trivyreport.txt | grep -cE '^Total: [1-9]')
            THIRD=$(awk '/PARTE 2/,0' reports/trivyreport.txt | grep -E '^Total: [1-9]' | grep -oE 'HIGH: [0-9]+' | awk -F': ' '{s+=$2} END {print s+0}')
            echo "own images: $OWN target(s) with findings | third-party: $THIRD HIGH (documented)" ;;
        kubelinter)  sed -n '/## 1\./,/## 2\./p' reports/kubelinter.txt | grep -m1 -E "No lint errors|found [0-9]+ lint errors" ;;
    esac
done
