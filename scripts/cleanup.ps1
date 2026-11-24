# Borra todo lo que el proyecto creo en Kubernetes.
# Uso: .\scripts\cleanup.ps1 [-All]
#   sin opciones: app (prod y dev, con los datos de Redis), generador de trafico,
#                 monitoreo, politicas, Kyverno y Falco
#   -All:         ademas Jenkins (contenedor, datos y permisos en Kubernetes)
#                 y el addon de Ingress de minikube
# minikube y las imagenes Docker no se borran. Para eso: minikube delete.
# Nota: este archivo debe ser solo ASCII (PowerShell 5.1 lee los .ps1 sin BOM como ANSI).
param([switch]$All)
Set-Location (Join-Path $PSScriptRoot "..")
Write-Host "==========================================" -ForegroundColor Red
Write-Host "  Cleaning Up Kubernetes Resources" -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Red

# App (releases de Helm). El PVC de Redis tiene "helm.sh/resource-policy: keep"
# (Helm no lo borra al desinstalar), asi que se elimina explicitamente.
helm uninstall shape-game -n default --ignore-not-found
helm uninstall shape-game-dev -n shape-dev --ignore-not-found
kubectl delete pvc -n default -l app.kubernetes.io/instance=shape-game --ignore-not-found=true
kubectl delete namespace shape-dev --ignore-not-found=true
kubectl delete job loadgen --ignore-not-found=true
kubectl delete configmap loadgen-script --ignore-not-found=true
# Monitoreo: el namespace incluye Prometheus, Grafana, Secret y ConfigMaps
kubectl delete -f k8s/monitoring/prometheus.yaml --ignore-not-found=true
kubectl delete namespace monitoring --ignore-not-found=true
# Seguridad: primero las politicas, despues Kyverno (quita sus webhooks) y Falco
kubectl delete -f k8s/security/policies/ --ignore-not-found=true
kubectl delete -f k8s/security/exceptions/ --ignore-not-found=true 2>$null
helm uninstall kyverno -n kyverno --ignore-not-found
helm uninstall falco -n falco --ignore-not-found
kubectl delete namespace kyverno falco --ignore-not-found=true

if ($All) {
    Write-Host "`n[-All] Jenkins y addon de Ingress..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "jenkins-down.ps1") -Purge
    minikube addons disable ingress
}

Write-Host "`n[OK] SUCCESS: All resources removed from Kubernetes." -ForegroundColor Green
if (-not $All) { Write-Host "     Jenkins sigue igual. Para borrarlo tambien: .\scripts\cleanup.ps1 -All" }
