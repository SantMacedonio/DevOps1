# PowerShell Deployment Script: Initial Blue (v1) & Redis Deployment
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Deploying Game Infrastructure to Minikube" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Deploy Redis
Write-Host "[1/3] Deploying Redis Database & Persistent Volume..." -ForegroundColor Yellow
kubectl apply -f k8s/redis.yaml
kubectl rollout status deployment/redis --timeout=90s

# 2. Deploy Blue (v1.0)
Write-Host "[2/3] Deploying Blue Application (v1.0)..." -ForegroundColor Blue
kubectl apply -f k8s/blue-deployment.yaml
kubectl rollout status deployment/shape-game-blue --timeout=90s

# 3. Deploy Kubernetes Service
Write-Host "[3/3] Configuring Blue/Green Service Router..." -ForegroundColor Yellow
kubectl apply -f k8s/service.yaml

Write-Host "`n[OK] SUCCESS: Blue (v1.0) is active and running!" -ForegroundColor Green
Write-Host "`n--- Cluster Status ---" -ForegroundColor Cyan
kubectl get pods,services -l app=shape-game

Write-Host "`n[->] To open the game in your browser, run:" -ForegroundColor Yellow
Write-Host "    minikube service shape-game-service" -ForegroundColor White
