# Spike SHA-256 su Windows: compila in AOT, esegue correttezza + benchmark +
# criteri (backend CNG). Exit 0 solo se tutti i criteri passano.
#   $env:HASH_SPIKE_DATA   dove generare i ~3,3 GiB di dati (default .tmp\data)
#   $env:HASH_SPIKE_QUICK  "1" = fallback puri misurati su 256 MiB
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$data = if ($env:HASH_SPIKE_DATA) { $env:HASH_SPIKE_DATA } else { '.tmp\data' }
New-Item -ItemType Directory -Force .tmp | Out-Null
dart pub get | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
dart analyze --fatal-infos
if ($LASTEXITCODE -ne 0) { exit 1 }
dart compile exe bin\bench.dart -o .tmp\bench.exe | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
$benchArgs = @('all', '--data', $data)
if ($env:HASH_SPIKE_QUICK -eq '1') { $benchArgs += '--quick' }
& .tmp\bench.exe @benchArgs
exit $LASTEXITCODE
