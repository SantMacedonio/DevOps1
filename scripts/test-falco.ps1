# Ejecuta acciones sospechosas dentro de un pod de la app y guarda las alertas
# que registra Falco en reports/falco-event.log (una alerta JSON por linea).
#   1. Abre una shell (regla propia "Shell en contenedor de Shape Popper")
#   2. Busca claves privadas (regla estandar "Search Private Keys or Passwords")
#   3. Si la terminal es interactiva, abre una shell con TTY
#      (regla estandar "Terminal shell in container")
Set-Location (Join-Path $PSScriptRoot "..")
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$out = "reports/falco-event.log"
New-Item -ItemType Directory -Force reports | Out-Null

# Pod de la version activa (la que tiene el Service en su selector)
$color = kubectl get svc shape-game -o jsonpath='{.spec.selector.version}'
$pod = kubectl get pod -l "app=shape-game,version=$color" -o jsonpath='{.items[0].metadata.name}'
$start = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Falco test on pod $pod" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "[1/3] Opening a shell inside the container..." -ForegroundColor Yellow
kubectl exec $pod -- sh -c 'id; hostname'

Write-Host "[2/3] Searching for private keys..." -ForegroundColor Yellow
kubectl exec $pod -- find / -name id_rsa 2>$null

if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    Write-Host "[3/3] Interactive shell with TTY (type 'exit' to continue)..." -ForegroundColor Yellow
    kubectl exec -it $pod -- sh
} else {
    Write-Host "[3/3] Skipped: this terminal is not interactive (no TTY)." -ForegroundColor Gray
    Write-Host "      To trigger 'Terminal shell in container' run: kubectl exec -it $pod -- sh" -ForegroundColor Gray
}

Write-Host "[*] Waiting for Falco to flush the events..." -ForegroundColor Yellow
Start-Sleep -Seconds 5
$events = kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --since-time=$start --tail=-1 |
    Where-Object { $_ -like '{*' -and $_ -like "*`"k8s.pod.name`":`"$pod`"*" }
[System.IO.File]::WriteAllLines((Join-Path (Get-Location) $out), [string[]]@($events), $utf8)

$count = @($events).Count
if ($count -gt 0) {
    Write-Host "`n[OK] Falco registered $count event(s) -> $out" -ForegroundColor Green
    $events | ForEach-Object { ($_ | ConvertFrom-Json).rule } | Group-Object | ForEach-Object { "  {0} x {1}" -f $_.Count, $_.Name }
} else {
    Write-Host "`n[X] No Falco events found for $pod" -ForegroundColor Red
    exit 1
}
