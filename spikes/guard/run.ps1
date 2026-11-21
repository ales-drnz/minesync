# Windows: compila guard, fake_server, fake_app, scenarios (AOT) ed esegue le
# prove (taskkill /F dell'app, kill del guard con Job Object, taskkill /T).
# Exit code 0 solo se passano tutti gli scenari gating di Windows.
# uso: pwsh -File run.ps1 [--only nome1,nome2]
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$bin = Join-Path $PSScriptRoot '.tmp\bin'
$work = Join-Path $PSScriptRoot '.tmp\work'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
dart pub get | Out-Null
if ($LASTEXITCODE -ne 0) { exit 1 }
foreach ($n in 'guard', 'fake_server', 'fake_app', 'scenarios') {
  dart compile exe "bin\$n.dart" -o "$bin\$n.exe" | Out-Null
  if ($LASTEXITCODE -ne 0) { exit 1 }
}
& "$bin\scenarios.exe" --bin $bin --work $work --fixtures (Join-Path $PSScriptRoot 'fixtures') @args
exit $LASTEXITCODE
