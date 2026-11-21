# Esegue lo spike di auto-aggiornamento su Windows: exit 0 solo se tutti gli scenari passano.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
dart pub get | Out-Null
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
dart analyze --fatal-infos
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
dart run bin/e2e.dart
exit $LASTEXITCODE
