# Detiene Jenkins. Con "-Purge" borra tambien sus datos (volumen) y sus
# permisos en Kubernetes.
param([switch]$Purge)
Set-Location (Join-Path $PSScriptRoot "..")
docker rm -f shape-jenkins *> $null
if ($LASTEXITCODE -eq 0) { Write-Host "[OK] Jenkins stopped" -ForegroundColor Green }
if ($Purge) {
    docker volume rm shape-jenkins-home *> $null
    Write-Host "[OK] Jenkins data removed" -ForegroundColor Green
    kubectl delete -f k8s/jenkins/rbac.yaml --ignore-not-found=true *> $null
    if (Test-Path .jenkins) { Remove-Item -Recurse -Force .jenkins }
    Write-Host "[OK] Jenkins permissions and kubeconfig removed" -ForegroundColor Green
}
