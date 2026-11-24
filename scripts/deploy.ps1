# Despliega Shape Popper (app Blue/Green + Redis) con la Helm Chart.
# Uso: .\scripts\deploy.ps1 [-Env prod|dev]   (por defecto: prod)
#   prod -> release "shape-game"     en el namespace "default"   (values-prod.yaml)
#   dev  -> release "shape-game-dev" en el namespace "shape-dev" (values-dev.yaml)
param(
    [ValidateSet("prod", "dev")]
    [string]$Env = "prod"
)
Set-Location (Join-Path $PSScriptRoot "..")
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8

if ($Env -eq "prod") { $release = "shape-game"; $ns = "default" }
else { $release = "shape-game-dev"; $ns = "shape-dev" }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Deploying Shape Popper with Helm ($Env)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "[1/3] helm upgrade --install $release (namespace $ns)..." -ForegroundColor Yellow
# "upgrade --install": instala si no existe y actualiza si ya existe
helm upgrade --install $release ./helm-chart -f "helm-chart/values-$Env.yaml" -n $ns --create-namespace --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { Write-Host "[X] Helm deployment failed" -ForegroundColor Red; exit 1 }

Write-Host "[2/3] Pods:" -ForegroundColor Yellow
kubectl get pods -n $ns -l "app.kubernetes.io/instance=$release"

Write-Host "[3/3] helm test (service reachable + Redis connected)..." -ForegroundColor Yellow
helm test $release -n $ns --logs
if ($LASTEXITCODE -ne 0) { Write-Host "[X] helm test failed" -ForegroundColor Red; exit 1 }

Write-Host "`n[OK] SUCCESS: $release deployed in namespace $ns" -ForegroundColor Green
helm get notes $release -n $ns
