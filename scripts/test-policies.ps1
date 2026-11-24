# Valida las politicas de Kyverno intentando desplegar los manifiestos de
# k8s/security/tests/. Los "NO CONFORME" deben ser rechazados y el conforme
# aceptado. Se usa --dry-run=server: pasa por el webhook de Kyverno igual que
# un apply real, pero no crea nada en el cluster.
# Resultado: reports/kyverno-validation.log
# Nota: este archivo debe ser solo ASCII (PowerShell 5.1 lee los .ps1 sin BOM como ANSI).
Set-Location (Join-Path $PSScriptRoot "..")
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$out = Join-Path (Get-Location) "reports/kyverno-validation.log"
New-Item -ItemType Directory -Force reports | Out-Null
$failed = $false
$lines = New-Object System.Collections.Generic.List[string]

$lines.Add("Validacion de politicas Kyverno")
$lines.Add("Fecha:   " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'"))
$lines.Add("Kyverno: " + (kubectl get deploy -n kyverno kyverno-admission-controller -o jsonpath='{.spec.template.spec.containers[0].image}'))
$lines.Add("")
$lines.Add("Politicas activas:")
kubectl get validatingpolicies | ForEach-Object { $lines.Add($_) }
$lines.Add("")

foreach ($f in Get-ChildItem k8s/security/tests/*.yaml | Sort-Object Name) {
    $rel = "k8s/security/tests/$($f.Name)"
    $expected = if ($f.Name -like "*compliant*") { "ACEPTADO" } else { "RECHAZADO" }

    $output = (kubectl apply --dry-run=server -f $rel 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $result = if ($output -match "denied the request") { "RECHAZADO" } else { "ACEPTADO" }
    $status = if ($result -eq $expected) { "OK" } else { $failed = $true; "FALLO" }

    $lines.Add("------------------------------------------------------------")
    $lines.Add("Manifiesto: $rel")
    $lines.Add("Esperado:   $expected   Resultado: $result   [$status]")
    $lines.Add("`$ kubectl apply --dry-run=server -f $rel")
    $lines.Add($output)
    "{0,-35} esperado={1,-9} resultado={2,-9} [{3}]" -f $f.Name, $expected, $result, $status
}

[System.IO.File]::WriteAllLines($out, $lines, $utf8)

if (-not $failed) {
    Write-Host "`n[OK] All policies behave as expected -> reports/kyverno-validation.log" -ForegroundColor Green
} else {
    Write-Host "`n[X] Some policies did not behave as expected -> reports/kyverno-validation.log" -ForegroundColor Red
    exit 1
}
