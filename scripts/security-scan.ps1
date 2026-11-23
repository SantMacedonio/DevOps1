# Analisis de seguridad (DevSecOps). Genera en reports/:
#   npm-audit.txt   -> dependencias de Node.js con vulnerabilidades conocidas
#   semgrep.txt     -> analisis estatico del codigo (SAST)
#   trivyreport.txt -> vulnerabilidades y secretos en las imagenes Docker
#   kubelinter.txt  -> buenas practicas de seguridad en los manifiestos de Kubernetes
# Ejecutar antes .\scripts\build.ps1 (Trivy escanea las imagenes locales).
# Nota: este archivo debe ser solo ASCII (PowerShell 5.1 lee los .ps1 sin BOM como ANSI).
Set-Location (Join-Path $PSScriptRoot "..")
# UTF-8 al leer la salida de las herramientas y al escribir los reportes
# (en PowerShell 5.1 ">" escribe UTF-16 y los pipes usan ASCII)
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$SemgrepVersion = "1.186.0"
$TrivyVersion = "0.76.1"
$KubeLinterVersion = "v0.8.3"
$OwnImages = @("shape-game:v1", "shape-game:v2", "shape-redis:1.0.0")
$ThirdPartyImages = @("prom/prometheus:v3.16.0", "grafana/grafana:13.3.1")
New-Item -ItemType Directory -Force reports | Out-Null
$root = (Get-Location).Path
$esc = [char]27

$hasTrivy = $null -ne (Get-Command trivy -ErrorAction SilentlyContinue)
$hasKubeLinter = $null -ne (Get-Command kube-linter -ErrorAction SilentlyContinue)

function Write-Report {
    param([string]$Name, [System.Collections.Generic.List[string]]$Lines)
    [System.IO.File]::WriteAllLines((Join-Path $root "reports/$Name"), $Lines, $utf8)
}
function New-Report {
    param([string]$Title, [string]$Command)
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("# $Title")
    $l.Add("# Fecha: " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'"))
    $l.Add("# Comando: $Command")
    $l.Add("")
    return ,$l
}
function Add-Output {
    param([System.Collections.Generic.List[string]]$Lines, $Output)
    foreach ($o in $Output) { $Lines.Add(("$o" -replace "$esc\[[0-9;]*[A-Za-z]", "")) }
}
function Invoke-Trivy {
    if ($hasTrivy) { trivy image --quiet @args 2>&1 }
    else { docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "aquasec/trivy:$TrivyVersion" image --quiet @args 2>&1 }
}
function Invoke-KubeLinter {
    if ($hasKubeLinter) { kube-linter lint @args 2>&1 }
    else { docker run --rm -v "${root}:/src" -w /src "stackrox/kube-linter:$KubeLinterVersion" lint @args 2>&1 }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Security scan (npm audit, Semgrep, Trivy, KubeLinter)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 1. npm audit -----------------------------------------------------------
Write-Host "[1/4] npm audit..." -ForegroundColor Yellow
$r = New-Report "npm audit - npm $(npm --version)" "npm audit"
Add-Output $r (npm audit 2>&1)
$r.Add("")
$r.Add("## Resumen (npm audit --json)")
$audit = (npm audit --json 2>$null) -join "`n" | ConvertFrom-Json
$r.Add("Vulnerabilidades: " + ($audit.metadata.vulnerabilities | ConvertTo-Json -Compress))
$r.Add("Dependencias analizadas: " + ($audit.metadata.dependencies | ConvertTo-Json -Compress))
Write-Report "npm-audit.txt" $r

# --- 2. Semgrep ---------------------------------------------------------------
Write-Host "[2/4] Semgrep $SemgrepVersion..." -ForegroundColor Yellow
$configs = @("p/javascript", "p/nodejs", "p/expressjs", "p/xss", "p/owasp-top-ten", "p/security-audit", "p/secrets", "p/dockerfile", "p/kubernetes")
$configArgs = $configs | ForEach-Object { "--config"; $_ }
$r = New-Report "Semgrep $SemgrepVersion (SAST)" ("semgrep scan " + (($configs | ForEach-Object { "--config $_" }) -join " ") + " --no-git-ignore")
$out = docker run --rm -v "${root}:/src" -w /src "semgrep/semgrep:$SemgrepVersion" semgrep scan @configArgs --metrics=off --no-git-ignore --exclude node_modules --exclude reports --exclude .git --exclude k8s/security/tests 2>&1
Add-Output $r ($out | Where-Object { "$_" -notmatch 'Pulling|Download|Pull complete|Digest:|Status:' })
Write-Report "semgrep.txt" $r

# --- 3. Trivy -----------------------------------------------------------------
Write-Host "[3/4] Trivy..." -ForegroundColor Yellow
$r = New-Report "Trivy (vulnerabilidades y secretos)" "trivy image --scanners vuln,secret <imagen>"
$r.Add("############################################################")
$r.Add("# PARTE 1: imagenes propias (todas las severidades)")
$r.Add("############################################################")
foreach ($img in $OwnImages) {
    $r.Add(""); $r.Add("==================== $img ====================")
    Add-Output $r (Invoke-Trivy --scanners "vuln,secret" --format table $img)
}
$r.Add("")
$r.Add("############################################################")
$r.Add("# PARTE 2: imagenes de terceros usadas en el cluster (HIGH/CRITICAL)")
$r.Add("# Informativo: no se construyen en este proyecto. Ver reports/security-report.md")
$r.Add("############################################################")
foreach ($img in $ThirdPartyImages) {
    $r.Add(""); $r.Add("==================== $img ====================")
    docker pull -q $img *> $null
    Add-Output $r (Invoke-Trivy --scanners vuln --severity "HIGH,CRITICAL" --format table $img)
}
Write-Report "trivyreport.txt" $r
$trivyText = $r -join "`n"

# --- 4. KubeLinter --------------------------------------------------------------
Write-Host "[4/4] KubeLinter..." -ForegroundColor Yellow
$r = New-Report "KubeLinter $KubeLinterVersion" "kube-linter lint --ignore-paths 'k8s/security/tests/**' k8s/ helm-chart/"
$r.Add("## 1. Manifiestos del proyecto y Helm Chart (checks por defecto)")
Add-Output $r (Invoke-KubeLinter --ignore-paths 'k8s/security/tests/**' k8s/ helm-chart/)
$r.Add("")
$r.Add("## 2. Control: manifiestos NO CONFORMES de prueba de Kyverno (k8s/security/tests/)")
$r.Add("##    Se espera que KubeLinter tambien los marque (demuestra que la herramienta funciona).")
Add-Output $r (Invoke-KubeLinter k8s/security/tests/)
Write-Report "kubelinter.txt" $r
$lintText = $r -join "`n"

# --- Resumen ------------------------------------------------------------------
Write-Host "`n[OK] Reports generated:" -ForegroundColor Green
$npmLine = (Select-String -Path reports/npm-audit.txt -Pattern "found \d+ vulnerabilit" | Select-Object -First 1).Line
$semLine = (Select-String -Path reports/semgrep.txt -Pattern "Ran \d+ rules" | Select-Object -First 1).Line
$ownPart = ($trivyText -split "# PARTE 2")[0]
$ownFindings = ([regex]::Matches($ownPart, "(?m)^Total: [1-9]")).Count
$thirdHigh = 0
foreach ($m in [regex]::Matches(($trivyText -split "# PARTE 2")[1], "(?m)^Total: .*HIGH: (\d+)")) { $thirdHigh += [int]$m.Groups[1].Value }
$lintLine = (($lintText -split "## 2\.")[0] -split "`n" | Where-Object { $_ -match "No lint errors|found \d+ lint errors" } | Select-Object -First 1)
"  reports/npm-audit.txt    $npmLine"
"  reports/semgrep.txt      $semLine"
"  reports/trivyreport.txt  own images: $ownFindings target(s) with findings | third-party: $thirdHigh HIGH (documented)"
"  reports/kubelinter.txt   $lintLine"
