# Levanta Jenkins (contenedor "shape-jenkins") listo para correr el pipeline:
#   1. Permisos de Jenkins en Kubernetes (k8s/jenkins/rbac.yaml)
#   2. kubeconfig de la ServiceAccount jenkins-deployer -> .jenkins/kubeconfig
#   3. Credenciales desde .env.jenkins (se crea desde .env.jenkins.example)
#   4. Imagen de Jenkins (jenkins/Dockerfile) y contenedor
# Jenkins queda en http://localhost:8080 (usuario admin).
# Nota: este archivo debe ser solo ASCII (PowerShell 5.1 lee los .ps1 sin BOM como ANSI).
Set-Location (Join-Path $PSScriptRoot "..")
$utf8 = New-Object System.Text.UTF8Encoding $false
$root = (Get-Location).Path

$image = "shape-jenkins:1.0.0"
$container = "shape-jenkins"

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { Write-Host "[X] Error: $Description" -ForegroundColor Red; exit 1 }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Starting Jenkins" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "[1/5] Kubernetes permissions for Jenkins (jenkins-deployer)..." -ForegroundColor Yellow
Invoke-Checked "applying k8s/jenkins/rbac.yaml" { kubectl apply -f k8s/jenkins/rbac.yaml | Out-Null }
do { $tokenB64 = kubectl get secret jenkins-deployer-token -n jenkins-ci -o jsonpath='{.data.token}' 2>$null; if (-not $tokenB64) { Start-Sleep -Seconds 1 } } while (-not $tokenB64)

Write-Host "[2/5] kubeconfig with the jenkins-deployer token -> .jenkins/kubeconfig" -ForegroundColor Yellow
New-Item -ItemType Directory -Force .jenkins | Out-Null
$token = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tokenB64))
$ca = kubectl get secret jenkins-deployer-token -n jenkins-ci -o jsonpath='{.data.ca\.crt}'
$server = "https://$(minikube ip):8443"
$kubeconfig = @"
apiVersion: v1
kind: Config
clusters:
  - name: minikube
    cluster:
      server: $server
      certificate-authority-data: $ca
users:
  - name: jenkins-deployer
    user:
      token: $token
contexts:
  - name: jenkins
    context:
      cluster: minikube
      user: jenkins-deployer
      namespace: default
current-context: jenkins
"@
[System.IO.File]::WriteAllText((Join-Path $root ".jenkins/kubeconfig"), ($kubeconfig -replace "`r`n", "`n"), $utf8)

Write-Host "[3/5] Credentials (.env.jenkins)..." -ForegroundColor Yellow
if (-not (Test-Path .env.jenkins)) {
    Copy-Item .env.jenkins.example .env.jenkins
    Write-Host "      .env.jenkins created from .env.jenkins.example"
}
$envLines = [System.IO.File]::ReadAllLines((Join-Path $root ".env.jenkins"))
if (-not ($envLines | Where-Object { $_ -match '^JENKINS_ADMIN_PASSWORD=.+' })) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $pass = -join (1..16 | ForEach-Object { $chars | Get-Random })
    $envLines = $envLines | ForEach-Object { if ($_ -match '^JENKINS_ADMIN_PASSWORD=') { "JENKINS_ADMIN_PASSWORD=$pass" } else { $_ } }
    [System.IO.File]::WriteAllLines((Join-Path $root ".env.jenkins"), [string[]]$envLines, $utf8)
    Write-Host "      Generated a random admin password"
}
if (-not ($envLines | Where-Object { $_ -match '^SNYK_TOKEN=.+' })) {
    Write-Host "      [!] SNYK_TOKEN is empty: the Snyk stage will fail until you set it" -ForegroundColor DarkYellow
}

Write-Host "[4/5] Building $image..." -ForegroundColor Yellow
Invoke-Checked "building the Jenkins image" { docker build -t $image jenkins/ }

Write-Host "[5/5] Starting container $container..." -ForegroundColor Yellow
docker rm -f $container *> $null
# --network minikube : para llegar a la API de Kubernetes (IP del nodo)
# docker.sock        : para construir imagenes con el Docker del host
# --group-add 0      : el socket es root:root 660; Jenkins sigue siendo uid 1000
# /repo (solo lectura): repositorio local que clona el pipeline
Invoke-Checked "starting Jenkins" {
    docker run -d --name $container --network minikube -p 8080:8080 --memory 1500m --group-add 0 `
        -v shape-jenkins-home:/var/jenkins_home `
        -v /var/run/docker.sock:/var/run/docker.sock `
        -v "${root}:/repo:ro" `
        -v "${root}/.jenkins/kubeconfig:/run/secrets/kubeconfig:ro" `
        --env-file .env.jenkins `
        $image | Out-Null
}

Write-Host -NoNewline "      Waiting for Jenkins"
do {
    Start-Sleep -Seconds 3
    Write-Host -NoNewline "."
    try { $code = (Invoke-WebRequest -Uri http://localhost:8080/login -UseBasicParsing -TimeoutSec 5).StatusCode } catch { $code = 0 }
} while ($code -ne 200)
Write-Host ""

$adminPass = (($envLines | Where-Object { $_ -match '^JENKINS_ADMIN_PASSWORD=' }) -split '=', 2)[1]
if (-not $adminPass) { $adminPass = ([System.IO.File]::ReadAllLines((Join-Path $root ".env.jenkins")) | Where-Object { $_ -match '^JENKINS_ADMIN_PASSWORD=' }) -replace '^JENKINS_ADMIN_PASSWORD=', '' }
Write-Host "`n[OK] Jenkins is running: http://localhost:8080" -ForegroundColor Green
Write-Host "     user: admin   password: $adminPass" -ForegroundColor White
Write-Host "     job:  shape-game (Build with Parameters)" -ForegroundColor White
