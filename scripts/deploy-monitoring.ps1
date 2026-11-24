# Despliega Prometheus + Grafana en el namespace "monitoring".
# El dashboard se carga desde grafana/dashboard.json (unica fuente de verdad).
Set-Location (Join-Path $PSScriptRoot "..")

# UTF-8 (sin BOM) al leer la salida de kubectl y al enviarle texto por pipe.
# Windows PowerShell 5.1 usa ASCII por defecto en los pipes hacia programas
# externos: los tildes del dashboard llegaban a Grafana como "??".
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[X] Error: $Description" -ForegroundColor Red
        exit 1
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Deploying Monitoring (Prometheus + Grafana)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "[1/4] Namespace..." -ForegroundColor Yellow
Invoke-Checked "creating namespace" { kubectl apply -f k8s/monitoring/namespace.yaml }

Write-Host "[2/4] Grafana admin secret & dashboard ConfigMap..." -ForegroundColor Yellow
# Contrasena aleatoria, generada una sola vez (no se guarda en el repositorio)
kubectl get secret grafana-admin -n monitoring *> $null
if ($LASTEXITCODE -ne 0) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $pass = -join (1..16 | ForEach-Object { $chars | Get-Random })
    Invoke-Checked "creating grafana secret" { kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-password=$pass }
}
$cm = kubectl create configmap grafana-dashboard -n monitoring --from-file=dashboard.json=grafana/dashboard.json --dry-run=client -o yaml
$dashResult = $cm | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { Write-Host "[X] Error: applying dashboard configmap" -ForegroundColor Red; exit 1 }
Write-Host $dashResult

Write-Host "[3/4] Prometheus..." -ForegroundColor Yellow
Invoke-Checked "applying prometheus" { kubectl apply -f k8s/monitoring/prometheus.yaml }
Invoke-Checked "waiting for prometheus" { kubectl rollout status deployment/prometheus -n monitoring --timeout=180s }
# Recarga la configuracion si el ConfigMap cambio (sin reiniciar el pod)
kubectl exec -n monitoring deploy/prometheus -- wget -qO- --post-data='' http://localhost:9090/-/reload *> $null

Write-Host "[4/4] Grafana..." -ForegroundColor Yellow
Invoke-Checked "applying grafana" { kubectl apply -f k8s/monitoring/grafana.yaml }
# Si el dashboard cambio, reiniciar Grafana para que lo cargue al instante
# (seguro: Grafana no guarda estado propio, todo se reprovisiona al iniciar)
if ("$dashResult" -match "configured") {
    Invoke-Checked "restarting grafana" { kubectl rollout restart deployment/grafana -n monitoring }
}
Invoke-Checked "waiting for grafana" { kubectl rollout status deployment/grafana -n monitoring --timeout=180s }

$b64 = kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}'
$pass = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))

Write-Host "`n[OK] SUCCESS: monitoring stack is running" -ForegroundColor Green
kubectl get pods,svc -n monitoring
Write-Host "`n[->] Prometheus: minikube service prometheus -n monitoring" -ForegroundColor Yellow
Write-Host "[->] Grafana:    minikube service grafana -n monitoring" -ForegroundColor Yellow
Write-Host "     user: admin   password: $pass   (anonymous read-only access is enabled)" -ForegroundColor White
