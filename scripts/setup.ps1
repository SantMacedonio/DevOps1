# Inicializa TODO el proyecto, en orden. Se puede volver a ejecutar: cada paso
# usa "helm upgrade --install" / "kubectl apply", que actualizan lo existente.
#   1. Verifica las herramientas (docker, minikube, kubectl, helm)
#   2. minikube (lo inicia si no esta corriendo) + addon de Ingress (ingress-nginx)
#   3. Operadores de seguridad: Kyverno (+ 4 politicas) y Falco
#   4. Imagenes Docker (build sin cache y carga en minikube)
#   5. App con Helm: prod (y dev con -WithDev)
#   6. Monitoreo: Prometheus + Grafana (con el dashboard)
#   7. Jenkins (con -WithJenkins)
# Uso: .\scripts\setup.ps1 [-WithDev] [-WithJenkins] [-All]
# Despues: .\scripts\generate-traffic.ps1 para poblar el dashboard.
# Ojo: vuelve prod al estado inicial (blue = shape-game:v1 activo, green = v2).
# Nota: este archivo debe ser solo ASCII (PowerShell 5.1 lee los .ps1 sin BOM como ANSI).
param([switch]$WithDev, [switch]$WithJenkins, [switch]$All)
Set-Location (Join-Path $PSScriptRoot "..")
if ($All) { $WithDev = $true; $WithJenkins = $true }
$minikubeMemory = if ($env:MINIKUBE_MEMORY) { $env:MINIKUBE_MEMORY } else { "4096" }
$minikubeCpus = if ($env:MINIKUBE_CPUS) { $env:MINIKUBE_CPUS } else { "2" }
$start = Get-Date

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "############################################################" -ForegroundColor Cyan
    Write-Host "#  $Text" -ForegroundColor Cyan
    Write-Host "############################################################" -ForegroundColor Cyan
}
# Ejecuta un script del proyecto y corta si falla
function Invoke-Step([string]$Script, [hashtable]$Params = @{}) {
    & (Join-Path $PSScriptRoot $Script) @Params
    if ($LASTEXITCODE -ne 0) { Write-Host "[X] Fallo $Script" -ForegroundColor Red; exit 1 }
}

Write-Step "[1/7] Herramientas"
foreach ($tool in "docker", "minikube", "kubectl", "helm") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "[X] Falta '$tool' (ver Prerrequisitos en el README)" -ForegroundColor Red; exit 1
    }
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Write-Host "[X] Docker no responde: inicia Docker Desktop" -ForegroundColor Red; exit 1 }
Write-Host "[OK] docker, minikube, kubectl y helm disponibles" -ForegroundColor Green

Write-Step "[2/7] minikube + Ingress"
$apiServer = minikube status --format "{{.APIServer}}" 2>$null
if ("$apiServer" -match "Running") {
    Write-Host "minikube ya esta corriendo"
} else {
    minikube start --memory=$minikubeMemory --cpus=$minikubeCpus
    if ($LASTEXITCODE -ne 0) { Write-Host "[X] minikube start fallo" -ForegroundColor Red; exit 1 }
}
minikube addons enable ingress
if ($LASTEXITCODE -ne 0) { Write-Host "[X] No se pudo habilitar el Ingress" -ForegroundColor Red; exit 1 }

Write-Step "[3/7] Operadores de seguridad: Kyverno + Falco"
Invoke-Step "install-security.ps1"

Write-Step "[4/7] Imagenes Docker"
Invoke-Step "build.ps1"

Write-Step "[5/7] App con Helm"
Invoke-Step "deploy.ps1" @{ Env = "prod" }
if ($WithDev) { Invoke-Step "deploy.ps1" @{ Env = "dev" } } else { Write-Host "dev omitido (usar -WithDev)" }

Write-Step "[6/7] Monitoreo: Prometheus + Grafana"
Invoke-Step "deploy-monitoring.ps1"

Write-Step "[7/7] Jenkins"
if ($WithJenkins) { Invoke-Step "jenkins-up.ps1" } else { Write-Host "Jenkins omitido (usar -WithJenkins)" }

$elapsed = (Get-Date) - $start
Write-Step ("Listo en {0} min {1} s" -f [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds)
Write-Host @"

Proximos pasos:
  .\scripts\generate-traffic.ps1           # jugadores simulados para poblar el dashboard
  minikube service shape-game              # abrir el juego (prod)
  minikube service grafana -n monitoring   # abrir Grafana (dashboard "Shape Popper")
  minikube service prometheus -n monitoring
  .\scripts\test-policies.ps1              # evidencia de Kyverno -> reports/kyverno-validation.log
  .\scripts\test-falco.ps1                 # evidencia de Falco   -> reports/falco-event.log
  .\scripts\security-scan.ps1              # npm audit, Snyk, Semgrep, Trivy, KubeLinter -> reports/
"@
if ($WithJenkins) { Write-Host "  Jenkins: http://localhost:8080 (usuario admin, contrasena en .env.jenkins)" }
exit 0
