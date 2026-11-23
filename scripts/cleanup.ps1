# PowerShell Script: Teardown all game resources in Kubernetes
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
helm uninstall kyverno -n kyverno --ignore-not-found
helm uninstall falco -n falco --ignore-not-found
kubectl delete namespace kyverno falco --ignore-not-found=true

Write-Host "`n[OK] SUCCESS: All resources removed from Kubernetes." -ForegroundColor Green
