# Prove dello spike pixel su Windows (runner windows-latest). Exit 0 solo se
# la geometria è pura a tutti i dpr sul motore reale e la fluidità passa.
#   pwsh ./run.ps1            (imposta $env:SKIP_PERF=1 per saltare la perf)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force .tmp | Out-Null
function Run($cmd) { Write-Host "> $cmd"; Invoke-Expression $cmd; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
Run 'flutter pub get'
# i golden di riferimento sono di Linux (testo diverso): qui solo motore reale
if (Test-Path .tmp/engine) { Remove-Item -Recurse -Force .tmp/engine }
$out = (Join-Path $PWD '.tmp/engine') -replace '\\','/'
Run "flutter test integration_test/capture_test.dart -d windows --dart-define=OUT=$out"
Run 'dart run tool/analyze_goldens.dart .tmp/engine --json .tmp/engine.json'
if (-not $env:SKIP_PERF) {
  Run 'flutter drive --profile -d windows --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart'
  Run 'dart run tool/check_perf.dart .tmp/perf.json'
}
Write-Host 'TUTTO PASS'
