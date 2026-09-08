# PowerShell Script: Teardown all game resources in Kubernetes
Write-Host "==========================================" -ForegroundColor Red
Write-Host "  Cleaning Up Kubernetes Resources" -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Red

kubectl delete -f k8s/green-deployment.yaml --ignore-not-found=true
kubectl delete -f k8s/blue-deployment.yaml --ignore-not-found=true
kubectl delete -f k8s/service.yaml --ignore-not-found=true
kubectl delete -f k8s/redis.yaml --ignore-not-found=true

Write-Host "`n[OK] SUCCESS: All resources removed from Kubernetes." -ForegroundColor Green
