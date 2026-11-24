# Simula jugadores para poblar el dashboard de Grafana.
# Uso: .\scripts\generate-traffic.ps1 [-Duration 300] [-Players 8]
#
# El trafico se genera con un Job DENTRO del cluster (k8s/loadgen/), para que
# pase por el Service y se reparta entre los pods. Un "kubectl port-forward"
# se fijaria a un unico pod y no seguiria el switch Blue -> Green.
param(
    [int]$Duration = 300,
    [int]$Players = 8
)
Set-Location (Join-Path $PSScriptRoot "..")

# UTF-8 (sin BOM) al leer la salida de kubectl y al enviarle texto por pipe
# (Windows PowerShell 5.1 usa ASCII por defecto y los tildes se vuelven "?").
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Generating traffic: ${Duration}s, $Players players" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$cm = kubectl create configmap loadgen-script --from-file=loadgen.sh=k8s/loadgen/loadgen.sh --dry-run=client -o yaml
$cm | kubectl apply -f -
kubectl delete job loadgen --ignore-not-found=true --wait=true

$job = (Get-Content k8s/loadgen/job.yaml -Raw -Encoding UTF8) -replace '__DURATION__', $Duration -replace '__PLAYERS__', $Players
$job | kubectl apply -f -
if ($LASTEXITCODE -ne 0) { Write-Host "[X] Error creating the load generator Job" -ForegroundColor Red; exit 1 }

kubectl wait --for=condition=Ready pod -l job-name=loadgen --timeout=120s
Write-Host "[*] Following load generator logs (Ctrl+C stops following; the Job keeps running)..." -ForegroundColor Yellow
kubectl logs -f job/loadgen
