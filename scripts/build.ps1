# Construye las imagenes Docker del proyecto y las carga en Minikube.
#   - shape-game:v1      (Blue,  v1.0.0)
#   - shape-game:v2      (Green, v2.0.0)
#   - shape-redis:1.0.1  (Redis con configuracion propia, no root)
Set-Location (Join-Path $PSScriptRoot "..")

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[X] Error: $Description" -ForegroundColor Red
        exit 1
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Building Shape Popper Docker Images" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "[1/3] Building Blue (v1.0) image: shape-game:v1 ..." -ForegroundColor Blue
Invoke-Checked "building shape-game:v1" { docker build --pull --no-cache --build-arg APP_VERSION=v1.0.0 --build-arg APP_COLOR=blue -t shape-game:v1 . }

Write-Host "[2/3] Building Green (v2.0) image: shape-game:v2 ..." -ForegroundColor Green
Invoke-Checked "building shape-game:v2" { docker build --pull --no-cache --build-arg APP_VERSION=v2.0.0 --build-arg APP_COLOR=green -t shape-game:v2 . }

Write-Host "[3/3] Building Redis image: shape-redis:1.0.1 ..." -ForegroundColor Yellow
Invoke-Checked "building shape-redis:1.0.1" { docker build --pull --no-cache -t shape-redis:1.0.1 ./redis }

# Cargar las imagenes en Minikube (funciona con cualquier driver / runtime)
$mkHost = ""
try { $mkHost = & minikube status --format='{{.Host}}' 2>$null } catch { }
if ($mkHost -match "Running") {
    Write-Host "`n[*] Loading images into Minikube..." -ForegroundColor Yellow
    Invoke-Checked "loading shape-game:v1" { minikube image load shape-game:v1 }
    Invoke-Checked "loading shape-game:v2" { minikube image load shape-game:v2 }
    Invoke-Checked "loading shape-redis:1.0.1" { minikube image load shape-redis:1.0.1 }
    Write-Host "[OK] Images available inside Minikube" -ForegroundColor Green
} else {
    Write-Host "`n[!] Minikube is not running: images were built only in the local Docker daemon." -ForegroundColor Gray
    Write-Host "    Run 'minikube start' and execute this script again before deploying." -ForegroundColor Gray
}

Write-Host "`n[OK] SUCCESS: images built" -ForegroundColor Green
docker images --format "table {{.Repository}}:{{.Tag}}`t{{.Size}}" | Select-String -Pattern "REPOSITORY|shape-"
