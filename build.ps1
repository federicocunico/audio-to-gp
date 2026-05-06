#Requires -Version 5.1
<#
.SYNOPSIS
    Build audio-to-gp Flutter Windows release.

.DESCRIPTION
    Runs flutter pub get + flutter build windows --release.
    Optionally packages the output into a zip archive.

.PARAMETER Package
    After a successful build, zip the release folder to dist\audio-to-gp-win64.zip.

.PARAMETER Clean
    Run flutter clean before building.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Clean -Package
#>
param(
    [switch]$Package,
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = Join-Path $PSScriptRoot 'audio_to_gp_flutter'
$ReleaseDir = Join-Path $ProjectDir 'build\windows\x64\runner\Release'
$DistDir    = Join-Path $PSScriptRoot 'dist'

Push-Location $ProjectDir
try {
    # ── Verify flutter is available ──────────────────────────────────────────
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Error 'flutter not found on PATH. Install Flutter and ensure it is on your PATH.'
    }

    Write-Host "`n==> Flutter version" -ForegroundColor Cyan
    flutter --version

    # ── Optional clean ───────────────────────────────────────────────────────
    if ($Clean) {
        Write-Host "`n==> flutter clean" -ForegroundColor Cyan
        flutter clean
    }

    # ── Pub get ──────────────────────────────────────────────────────────────
    Write-Host "`n==> flutter pub get" -ForegroundColor Cyan
    flutter pub get

    # ── Build ────────────────────────────────────────────────────────────────
    Write-Host "`n==> flutter build windows --release" -ForegroundColor Cyan
    flutter build windows --release

    $exe = Join-Path $ReleaseDir 'audio_to_gp_flutter.exe'
    if (-not (Test-Path $exe)) {
        Write-Error "Build succeeded but exe not found at: $exe"
    }

    $size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
    Write-Host "`n==> Built: $exe  ($size MB)" -ForegroundColor Green

    # ── Optional package ─────────────────────────────────────────────────────
    if ($Package) {
        Write-Host "`n==> Packaging to dist\" -ForegroundColor Cyan

        if (-not (Test-Path $DistDir)) {
            New-Item -ItemType Directory -Path $DistDir | Out-Null
        }

        $zipPath = Join-Path $DistDir 'audio-to-gp-win64.zip'
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

        Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $zipPath
        $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-Host "==> Archive: $zipPath  ($zipSize MB)" -ForegroundColor Green
    }

    Write-Host "`nBuild complete." -ForegroundColor Green
} finally {
    Pop-Location
}
