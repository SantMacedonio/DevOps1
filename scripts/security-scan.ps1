# Analisis de seguridad (DevSecOps). Genera en reports/:
#   npm-audit.txt       -> dependencias de Node.js con vulnerabilidades conocidas (npm audit)
#   snyk-report.txt     -> dependencias con vulnerabilidades conocidas (Snyk) y correcciones propuestas
#   semgrep-report.txt  -> analisis estatico del codigo (SAST), con reglas oficiales y propias
#   trivyreport.txt -> vulnerabilidades y secretos en las imagenes Docker
#   kubelinter.txt  -> buenas practicas de seguridad en los manifiestos de Kubernetes
# Ejecutar antes .\scripts\build.ps1 (Trivy escanea las imagenes locales).
# Snyk necesita un token: se toma de la variable SNYK_TOKEN o de .env.jenkins.
# Nota: este archivo debe ser solo ASCII (PowerShell 5.1 lee los .ps1 sin BOM como ANSI).
Set-Location (Join-Path $PSScriptRoot "..")
# UTF-8 al leer la salida de las herramientas y al escribir los reportes
# (en PowerShell 5.1 ">" escribe UTF-16 y los pipes usan ASCII)
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$SemgrepVersion = "1.186.0"
$SnykVersion = "1.1309.0"
$TrivyVersion = "0.76.1"
$KubeLinterVersion = "v0.8.3"
$OwnImages = @("shape-game:v1", "shape-game:v2", "shape-redis:1.0.1")
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
Write-Host "  Security scan (npm audit, Snyk, Semgrep, Trivy, KubeLinter)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# --- 1. npm audit -----------------------------------------------------------
Write-Host "[1/5] npm audit..." -ForegroundColor Yellow
$r = New-Report "npm audit - npm $(npm --version)" "npm audit"
Add-Output $r (npm audit 2>&1)
$r.Add("")
$r.Add("## Resumen (npm audit --json)")
$audit = (npm audit --json 2>$null) -join "`n" | ConvertFrom-Json
$r.Add("Vulnerabilidades: " + ($audit.metadata.vulnerabilities | ConvertTo-Json -Compress))
$r.Add("Dependencias analizadas: " + ($audit.metadata.dependencies | ConvertTo-Json -Compress))
Write-Report "npm-audit.txt" $r

# --- 2. Snyk ------------------------------------------------------------------
Write-Host "[2/5] Snyk $SnykVersion..." -ForegroundColor Yellow
$snykToken = $env:SNYK_TOKEN
if (-not $snykToken -and (Test-Path .env.jenkins)) {
    $tokenLine = Select-String -Path .env.jenkins -Pattern '^SNYK_TOKEN=' | Select-Object -First 1
    if ($tokenLine) { $snykToken = $tokenLine.Line.Substring(11) }
}
$r = New-Report "Snyk CLI $SnykVersion (dependencias npm)" "snyk test --json-file-output=<archivo>"
if (-not $snykToken -or $snykToken -eq "not-set") {
    $r.Add("[!] No se ejecuto: falta SNYK_TOKEN (variable de entorno o linea SNYK_TOKEN= en .env.jenkins).")
} else {
    $snykJson = Join-Path ([System.IO.Path]::GetTempPath()) ("snyk-" + [guid]::NewGuid() + ".json")
    # El token viaja solo como variable de entorno y se restaura el valor anterior al terminar
    $prevToken = $env:SNYK_TOKEN
    $env:SNYK_TOKEN = $snykToken
    # Version fija de la CLI con npx; se omite la linea "Organization" (dato de la cuenta)
    $out = npx --yes "snyk@$SnykVersion" test "--json-file-output=$snykJson" 2>&1
    $env:SNYK_TOKEN = $prevToken
    Add-Output $r ($out | Where-Object { "$_" -notmatch '^Organization:' })
    $r.Add("")
    $r.Add("## Resumen, vulnerabilidades criticas y correcciones propuestas")
    Add-Output $r (node ci/snyk-summary.js $snykJson)
    Remove-Item -Force $snykJson -ErrorAction SilentlyContinue
}
Write-Report "snyk-report.txt" $r

# --- 3. Semgrep ---------------------------------------------------------------
Write-Host "[3/5] Semgrep $SemgrepVersion..." -ForegroundColor Yellow
# Conjuntos oficiales + reglas propias del proyecto (semgrep/shape-popper.yaml)
$configs = @("p/javascript", "p/nodejs", "p/expressjs", "p/xss", "p/owasp-top-ten", "p/security-audit", "p/secrets", "p/dockerfile", "p/kubernetes", "semgrep/shape-popper.yaml")
$configArgs = $configs | ForEach-Object { "--config"; $_ }
$r = New-Report "Semgrep $SemgrepVersion (SAST)" ("semgrep scan " + (($configs | ForEach-Object { "--config $_" }) -join " ") + " --no-git-ignore")
$r.Add("## 1. Analisis del proyecto (reglas oficiales + reglas propias)")
# semgrep/shape-popper.js y k8s/security/tests tienen codigo inseguro a proposito (casos de prueba)
$out = docker run --rm -v "${root}:/src" -w /src "semgrep/semgrep:$SemgrepVersion" semgrep scan @configArgs --metrics=off --no-git-ignore --exclude node_modules --exclude reports --exclude .git --exclude k8s/security/tests --exclude semgrep/shape-popper.js 2>&1
Add-Output $r ($out | Where-Object { "$_" -notmatch 'Pulling|Download|Pull complete|Digest:|Status:' })
$r.Add("")
$r.Add("## 2. Prueba de las reglas propias (semgrep --test semgrep/)")
$r.Add("##    Cada regla debe detectar los casos inseguros y no marcar los seguros.")
Add-Output $r (docker run --rm -v "${root}:/src" -w /src "semgrep/semgrep:$SemgrepVersion" semgrep --test --metrics=off semgrep/ 2>&1)
Write-Report "semgrep-report.txt" $r

# --- 4. Trivy -----------------------------------------------------------------
Write-Host "[4/5] Trivy..." -ForegroundColor Yellow
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

# --- 5. KubeLinter --------------------------------------------------------------
Write-Host "[5/5] KubeLinter..." -ForegroundColor Yellow
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
$semLine = (Select-String -Path reports/semgrep-report.txt -Pattern "Ran \d+ rules" | Select-Object -First 1).Line
$semTest = (Select-String -Path reports/semgrep-report.txt -Pattern "tests passed|failed" | Select-Object -First 1).Line
$snykLine = (Select-String -Path reports/snyk-report.txt -Pattern "^Vulnerabilidades:|No se ejecuto" | Select-Object -First 1).Line
$ownPart = ($trivyText -split "# PARTE 2")[0]
$ownFindings = ([regex]::Matches($ownPart, "(?m)^Total: [1-9]")).Count
$thirdHigh = 0
foreach ($m in [regex]::Matches(($trivyText -split "# PARTE 2")[1], "(?m)^Total: .*HIGH: (\d+)")) { $thirdHigh += [int]$m.Groups[1].Value }
$lintLine = (($lintText -split "## 2\.")[0] -split "`n" | Where-Object { $_ -match "No lint errors|found \d+ lint errors" } | Select-Object -First 1)
"  reports/npm-audit.txt       $npmLine"
"  reports/snyk-report.txt     $snykLine"
"  reports/semgrep-report.txt  $semLine | $semTest"
"  reports/trivyreport.txt     own images: $ownFindings target(s) with findings | third-party: $thirdHigh HIGH (documented)"
"  reports/kubelinter.txt      $lintLine"
