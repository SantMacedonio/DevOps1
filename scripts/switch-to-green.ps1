# Switch Blue/Green: el Service pasa a enviar el trafico a la version GREEN.
# Es un "helm upgrade" que solo cambia app.activeColor (el resto de los valores
# de la release se conserva). Para deshacerlo: switch-to-blue o "helm rollback".
# Uso: .\scripts\switch-to-green.ps1 [-Env prod|dev]   (por defecto: prod)
param(
    [ValidateSet("prod", "dev")]
    [string]$Env = "prod"
)
Set-Location (Join-Path $PSScriptRoot "..")

if ($Env -eq "prod") { $release = "shape-game"; $ns = "default" }
else { $release = "shape-game-dev"; $ns = "shape-dev" }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Blue/Green switch -> GREEN ($Env)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "[1/3] helm upgrade $release --set app.activeColor=green..." -ForegroundColor Yellow
helm upgrade $release ./helm-chart -n $ns --reset-then-reuse-values --set app.activeColor=green --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { Write-Host "[X] helm upgrade failed" -ForegroundColor Red; exit 1 }

Write-Host "[2/3] Verifying (helm test)..." -ForegroundColor Yellow
helm test $release -n $ns --logs
if ($LASTEXITCODE -ne 0) { Write-Host "[X] helm test failed" -ForegroundColor Red; exit 1 }

Write-Host "[3/3] Release history:" -ForegroundColor Yellow
helm history $release -n $ns --max 5

Write-Host "`n[OK] SUCCESS: traffic now goes to GREEN" -ForegroundColor Green
Write-Host "     Player progress is preserved in Redis." -ForegroundColor Green
Write-Host "     Undo: .\scripts\switch-to-blue.ps1 -Env $Env   or   helm rollback $release -n $ns" -ForegroundColor Gray
