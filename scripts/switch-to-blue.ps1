# PowerShell Script: Rollback to Blue (v1.0)
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Rolling Back Traffic to Blue (v1.0)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Patch Service selector to blue
Write-Host "[1/1] Switching Service traffic selector to version: blue..." -ForegroundColor Yellow
kubectl set selector service shape-game-service "app=shape-game,version=blue"

Write-Host ""
Write-Host "[OK] SUCCESS: Rollback to Blue Complete!" -ForegroundColor Green
Write-Host "    - Active Version: BLUE (v1.0)" -ForegroundColor Cyan
Write-Host ""
Write-Host "--- Active Endpoints ---" -ForegroundColor Yellow
kubectl get pods,services -l app=shape-game
