# Compila hub e client su Windows. Stesse variabili e stesso output di
# scripts/build.sh (OUT, HUB_TARGETS, CLIENT_TARGETS, MINESYNC_DEFAULT_SERVER,
# MINESYNC_SIGN_KEY): vedi lì la documentazione.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$out = if ($env:OUT) { $env:OUT } else { Join-Path $root "dist" }
$version = (Get-Content (Join-Path $root "VERSION") -Raw).Trim()
$hubTargets = if ($null -ne $env:HUB_TARGETS) { $env:HUB_TARGETS } else { "linux/amd64 linux/arm64" }
$clientTargets = if ($null -ne $env:CLIENT_TARGETS) { $env:CLIENT_TARGETS } else { "windows/amd64 linux/amd64 linux/arm64 darwin/arm64 darwin/amd64" }
New-Item -ItemType Directory -Force (Join-Path $out "dl") | Out-Null

$saved = @{ GOOS = $env:GOOS; GOARCH = $env:GOARCH; CGO_ENABLED = $env:CGO_ENABLED; GOWORK = $env:GOWORK }
$env:CGO_ENABLED = "0"; $env:GOWORK = "off"
$common = @("-trimpath", "-buildvcs=false")

function Build-SignTool {
    $tool = Join-Path $out ".sign-tool.exe"
    Push-Location (Join-Path $root "scripts/sign")
    $env:GOOS = ""; $env:GOARCH = ""
    go build -o $tool .
    if ($LASTEXITCODE) { throw "build sign tool fallito" }
    Pop-Location
    return $tool
}

try {
    $sign = $null; $pubkey = ""
    if ($env:MINESYNC_SIGN_KEY) {
        $sign = Build-SignTool
        $pubkey = (& $sign pubkey $env:MINESYNC_SIGN_KEY).Trim()
    }

    foreach ($t in ($hubTargets -split '\s+' | Where-Object { $_ })) {
        $os, $arch = $t -split '/'
        Write-Host "==> hub $os/$arch ($version)"
        Push-Location (Join-Path $root "server")
        $env:GOOS = $os; $env:GOARCH = $arch
        go build @common -ldflags="-s -w -X minesync/server/internal/api.Version=$version" -o (Join-Path $out "minesync-hub-$os-$arch") .
        if ($LASTEXITCODE) { throw "build hub fallito" }
        Pop-Location
    }

    $ld = "-s -w -X minesync/client/internal/version.Client=$version" +
          " -X minesync/client/internal/config.DefaultServer=$($env:MINESYNC_DEFAULT_SERVER)" +
          " -X minesync/client/internal/selfupdate.PublicKey=$pubkey"
    $targets = @($clientTargets -split '\s+' | Where-Object { $_ })
    foreach ($t in $targets) {
        $os, $arch = $t -split '/'
        $ext = if ($os -eq "windows") { ".exe" } else { "" }
        Write-Host "==> client $os/$arch ($version)"
        Push-Location (Join-Path $root "client")
        $env:GOOS = $os; $env:GOARCH = $arch
        go build @common -ldflags="$ld" -o (Join-Path $out "dl/minesync-$os-$arch$ext") .
        if ($LASTEXITCODE) { throw "build client fallito" }
        Pop-Location
    }

    if ($targets.Count -gt 0) {
        if (-not $sign) { $sign = Build-SignTool }
        & $sign sums (Join-Path $out "dl")
        if ($env:MINESYNC_SIGN_KEY) {
            & $sign sign $env:MINESYNC_SIGN_KEY (Join-Path $out "dl/SHA256SUMS")
            Write-Host "==> SHA256SUMS firmato"
        } else {
            Write-Host "==> SHA256SUMS NON firmato (MINESYNC_SIGN_KEY non impostata)"
        }
    }
    if ($sign) { Remove-Item $sign -ErrorAction SilentlyContinue }
    Write-Host "Fatto: $out"
} finally {
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:$k" $saved[$k] }
    }
}
