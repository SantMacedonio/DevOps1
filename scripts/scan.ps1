# Analiza la calidad de las imagenes:
#   - Trivy: vulnerabilidades (binario local o contenedor aquasec/trivy)
#   - Dive : eficiencia y capas (binario local o contenedor wagoodman/dive)
#   - docker history / inspect: tamano y cantidad de capas
# Los resultados se guardan en reports/scans/. Ejecutar antes: .\scripts\build.ps1
Set-Location (Join-Path $PSScriptRoot "..")
# Leer la salida de docker/trivy/dive como UTF-8 (evita caracteres rotos en los reportes)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$TrivyVersion = "0.76.1"
$DiveVersion = "v0.13.1"
$Images = @("shape-game:v1", "shape-game:v2", "shape-redis:1.0.1")
$Out = "reports/scans"
New-Item -ItemType Directory -Force $Out | Out-Null

$hasTrivy = $null -ne (Get-Command trivy -ErrorAction SilentlyContinue)
$hasDive = $null -ne (Get-Command dive -ErrorAction SilentlyContinue)
$diveCi = (Resolve-Path ".dive-ci").Path
$summaryFile = Join-Path $Out "summary.txt"
"" | Out-File -Encoding utf8 $summaryFile

foreach ($img in $Images) {
    $name = $img -replace '[:/]', '_'
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  Analyzing $img" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $size = (docker images --format "{{.Size}}" $img | Select-Object -First 1)
    $content = [int64](docker image inspect $img --format "{{.Size}}")
    $layers = (docker image inspect $img --format "{{len .RootFS.Layers}}")
    docker history --format "table {{.Size}}`t{{.CreatedBy}}" $img | Out-File -Encoding utf8 (Join-Path $Out "layers-$name.txt")

    Write-Host "[1/2] Trivy..." -ForegroundColor Yellow
    $trivyFile = Join-Path $Out "trivy-$name.txt"
    if ($hasTrivy) {
        trivy image --quiet --scanners vuln --format table $img | Out-File -Encoding utf8 $trivyFile
    } else {
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "aquasec/trivy:$TrivyVersion" image --quiet --scanners vuln --format table $img | Out-File -Encoding utf8 $trivyFile
    }
    $vulns = (Select-String -Path $trivyFile -Pattern '^Total:' | ForEach-Object { ($_.Line -replace ' \(UNKNOWN.*', '') }) -join ', '
    if (-not $vulns) { $vulns = "0 (clean)" }

    Write-Host "[2/2] Dive..." -ForegroundColor Yellow
    $diveFile = Join-Path $Out "dive-$name.txt"
    $env:CI = "true"
    if ($hasDive) {
        $diveOut = dive --ci-config $diveCi $img 2>&1
    } else {
        $diveOut = docker run --rm -e CI=true -v /var/run/docker.sock:/var/run/docker.sock -v "${diveCi}:/.dive-ci:ro" "wagoodman/dive:$DiveVersion" --ci-config /.dive-ci $img 2>&1
    }
    $esc = [char]27
    $diveText = ($diveOut | ForEach-Object { "$_" -replace "$esc\[[0-9;]*[A-Za-z]", "" })
    $diveText | Out-File -Encoding utf8 $diveFile
    $eff = ($diveText | Select-String 'efficiency:' | Select-Object -First 1).Line.Trim()
    $wasted = ($diveText | Select-String 'wastedBytes:' | Select-Object -First 1).Line.Trim()
    $result = ($diveText | Select-String '^Result:' | Select-Object -First 1).Line

    $block = @(
        $img,
        "  size (disk)      : $size",
        "  size (content)   : $([math]::Round($content / 1MB)) MB",
        "  filesystem layers: $layers",
        "  trivy (OS / npm) : $vulns",
        "  dive $eff",
        "  dive $wasted",
        "  dive $result",
        ""
    )
    $block | ForEach-Object { Write-Host $_ }
    $block | Out-File -Encoding utf8 -Append $summaryFile
}

Write-Host "[OK] Reports saved in $Out/" -ForegroundColor Green
