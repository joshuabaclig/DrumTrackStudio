# DEVELOPER setup only. End users should install the packaged installer from the
# GitHub Releases page instead - it bundles everything and needs no Python.
#
# This script prepares a DEV environment for working on the app from a fresh clone:
# fetches the pinned third-party binaries into bin/ (hash-verified against
# tools.lock.json) and builds the env/ venv from requirements.lock.txt.
# Requires Python 3.10+ on PATH.

$ErrorActionPreference = 'Stop'
$Root   = $PSScriptRoot
$BinDir = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

function Get-FileIfMissing([string]$Url, [string]$Dest) {
    if (Test-Path -LiteralPath $Dest) { Write-Host "Already have $(Split-Path $Dest -Leaf)."; return }
    Write-Host "Downloading $(Split-Path $Dest -Leaf)..."
    Invoke-WebRequest -Uri $Url -OutFile $Dest
}

# ---------- pinned third-party binaries ----------
Get-FileIfMissing 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' `
    (Join-Path $BinDir 'yt-dlp.exe')

$ffmpegExe = Join-Path $BinDir 'ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ffmpegExe)) {
    Write-Host 'Downloading ffmpeg (~100MB, one time)...'
    $ffZip = Join-Path $env:TEMP 'dts_ffmpeg.zip'
    $ffTmp = Join-Path $env:TEMP 'dts_ffmpeg_extract'
    Invoke-WebRequest -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $ffZip
    Remove-Item -Recurse -Force $ffTmp -ErrorAction SilentlyContinue
    Expand-Archive -Path $ffZip -DestinationPath $ffTmp -Force
    $found = Get-ChildItem -Path $ffTmp -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
    Copy-Item $found.FullName $ffmpegExe -Force
    Copy-Item (Join-Path $found.DirectoryName 'ffprobe.exe') (Join-Path $BinDir 'ffprobe.exe') -Force
    Remove-Item $ffZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $ffTmp -ErrorAction SilentlyContinue
} else {
    Write-Host 'Already have ffmpeg.exe / ffprobe.exe.'
}

# verify what we have against the pinned hashes (warn-only for dev: upstream 'latest'
# may be newer than the pin; release builds hard-fail instead via Build-Runtime.ps1)
$lock = Get-Content (Join-Path $Root 'tools.lock.json') -Raw | ConvertFrom-Json
foreach ($tool in $lock.tools.PSObject.Properties) {
    $path = Join-Path $BinDir $tool.Name
    if (Test-Path -LiteralPath $path) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
        if ($actual -ne $tool.Value.sha256.ToLower()) {
            Write-Host "NOTE: bin\$($tool.Name) does not match the pinned hash in tools.lock.json." -ForegroundColor Yellow
            Write-Host '      (Upstream may have released a newer build. Test the app, then update tools.lock.json to re-pin.)'
        }
    }
}

# ---------- dev venv with pinned packages ----------
$EnvDir = Join-Path $Root 'env'
$VenvPy = Join-Path $EnvDir 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $VenvPy)) {
    Write-Host 'Creating Python virtual environment (requires Python 3.10+ on PATH)...'
    python -m venv $EnvDir
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create venv. Install Python 3.10+ from python.org and ensure "python" is on PATH.'
    }
}

Write-Host 'Installing pinned packages (torch is large; several minutes)...'
& $VenvPy -m pip install --upgrade pip
& $VenvPy -m pip install --index-url https://download.pytorch.org/whl/cpu `
    --extra-index-url https://pypi.org/simple `
    -r (Join-Path $Root 'requirements.lock.txt')

Write-Host ''
Write-Host 'Dev setup complete. Run the app with: powershell -File DrumTrackStudio.ps1' -ForegroundColor Green
Write-Host 'To build the distributable: Build-Runtime.ps1 -> Build-Exe.ps1 -> Build-Installer.ps1' -ForegroundColor Green
Read-Host 'Press Enter to close'
