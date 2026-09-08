# PowerShell Build Script for Minikube Docker Images
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Building Shape Popper Game Docker Images" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Point local docker CLI to Minikube's Docker daemon if minikube is active
try {
    Write-Host "[1/3] Configuring Docker environment for Minikube..." -ForegroundColor Yellow
    & minikube -p minikube docker-env --shell powershell | Invoke-Expression
} catch {
    Write-Host "[!] Note: Could not auto-bind Minikube docker-env. Building standard local Docker images." -ForegroundColor Gray
}

# Build Blue Image (v1.0)
Write-Host "[2/3] Building Blue (v1.0) Image: shape-game:v1 ..." -ForegroundColor Blue
docker build --build-arg APP_VERSION=v1.0.0 --build-arg APP_COLOR=blue -t shape-game:v1 .

if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Error building shape-game:v1" -ForegroundColor Red
    exit 1
}

# Build Green Image (v2.0)
Write-Host "[3/3] Building Green (v2.0) Image: shape-game:v2 ..." -ForegroundColor Green
docker build --build-arg APP_VERSION=v2.0.0 --build-arg APP_COLOR=green -t shape-game:v2 .

if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Error building shape-game:v2" -ForegroundColor Red
    exit 1
}

# If minikube is active, ensure images are loaded into Minikube container store
try {
    $mkHost = & minikube status --format='{{.Host}}' 2>$null
    if ($mkHost -match "Running") {
        Write-Host "`n[*] Transferring images into Minikube image cache..." -ForegroundColor Yellow
        minikube image load shape-game:v1
        minikube image load shape-game:v2
        Write-Host "[OK] Images synced with Minikube containerd store!" -ForegroundColor Green
    }
} catch {
    # Non-blocking if minikube is not running
}

Write-Host "`n[OK] SUCCESS: Both Docker images built and ready!" -ForegroundColor Green
Write-Host "    - shape-game:v1 (Blue Edition)" -ForegroundColor Cyan
Write-Host "    - shape-game:v2 (Green Edition)" -ForegroundColor Green
