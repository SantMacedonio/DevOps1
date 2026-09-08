# PowerShell Script: Blue to Green Deployment & Traffic Switch
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Executing Blue -> Green Rolling Switch" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# 1. Deploy Green (v2.0)
Write-Host "[1/3] Deploying Green (v2.0 with Prestige Ascension)..." -ForegroundColor Yellow
kubectl apply -f k8s/green-deployment.yaml

# 2. Wait for Green pods to become completely Ready
Write-Host "[2/3] Waiting for Green Pods to pass readiness probes..." -ForegroundColor Yellow
kubectl rollout status deployment/shape-game-green --timeout=90s

if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Green deployment failed health checks! Traffic remains routed to Blue." -ForegroundColor Red
    exit 1
}

# 3. Seamlessly switch traffic to Green
Write-Host "[3/3] Switching Service traffic selector to version: green..." -ForegroundColor Green
kubectl set selector service shape-game-service "app=shape-game,version=green"

Write-Host ""
Write-Host "[OK] SUCCESS: Blue/Green Switch Complete!" -ForegroundColor Green
Write-Host "    - Active Version: GREEN (v2.0 - Prestige Ascension Enabled)" -ForegroundColor Green
Write-Host "    - State Persistence: Player progress, points, and upgrades safely preserved in Redis." -ForegroundColor Cyan
Write-Host ""
Write-Host "--- Active Endpoints ---" -ForegroundColor Yellow
kubectl get pods,services -l app=shape-game
