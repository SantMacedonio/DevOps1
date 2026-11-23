# Instala las herramientas de seguridad del cluster:
#   - Kyverno + 3 politicas (latest tag, requests/limits, no root)
#   - Falco (seguridad en tiempo de ejecucion) con la regla propia de Shape Popper
# Requiere: helm, kubectl y minikube en ejecucion.
Set-Location (Join-Path $PSScriptRoot "..")

$KyvernoChartVersion = "3.10.0"   # Kyverno v1.20.0
$FalcoChartVersion = "9.2.2"      # Falco 0.45.2

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[X] Error: $Description" -ForegroundColor Red
        exit 1
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Installing security tools (Kyverno + Falco)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "[1/4] Helm repositories..." -ForegroundColor Yellow
helm repo add kyverno https://kyverno.github.io/kyverno/ *> $null
helm repo add falcosecurity https://falcosecurity.github.io/charts *> $null
Invoke-Checked "updating helm repos" { helm repo update kyverno falcosecurity }

Write-Host "[2/4] Kyverno $KyvernoChartVersion..." -ForegroundColor Yellow
Invoke-Checked "installing kyverno" { helm upgrade --install kyverno kyverno/kyverno --version $KyvernoChartVersion -n kyverno --create-namespace -f k8s/security/kyverno-values.yaml --wait --timeout 6m }

Write-Host "[3/4] Kyverno policies..." -ForegroundColor Yellow
Invoke-Checked "applying policies" { kubectl apply -f k8s/security/policies/ }
Invoke-Checked "waiting for policies" { kubectl wait validatingpolicy --all --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=120s }

Write-Host "[4/4] Falco $FalcoChartVersion..." -ForegroundColor Yellow
Invoke-Checked "installing falco" { helm upgrade --install falco falcosecurity/falco --version $FalcoChartVersion -n falco --create-namespace -f k8s/security/falco-values.yaml --wait --timeout 6m }

Write-Host "`n[OK] SUCCESS: security tools installed" -ForegroundColor Green
kubectl get validatingpolicies
kubectl get pods -n kyverno
kubectl get pods -n falco
Write-Host "`n[->] Validate the policies: .\scripts\test-policies.ps1" -ForegroundColor Yellow
Write-Host "[->] Test Falco:            .\scripts\test-falco.ps1" -ForegroundColor Yellow
