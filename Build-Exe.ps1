# Compiles DrumTrackStudio.ps1 into DrumTrackStudio.exe (no console window).
# Run once, right-click > "Run with PowerShell" (or from a PowerShell prompt).
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing PS2EXE module (one time, current user only)...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$icon = Join-Path $Root 'app.ico'
$params = @{
    inputFile  = Join-Path $Root 'DrumTrackStudio.ps1'
    outputFile = Join-Path $Root 'DrumTrackStudio.exe'
    noConsole  = $true
    title      = 'Drum Track Studio'
    product    = 'Drum Track Studio'
}
if (Test-Path $icon) { $params.iconFile = $icon }

Invoke-ps2exe @params
Write-Host ''
Write-Host 'Built: DrumTrackStudio.exe - double-click it to launch (no terminal).' -ForegroundColor Green
Read-Host 'Press Enter to close'
