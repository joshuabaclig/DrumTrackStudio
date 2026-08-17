# One-time setup for a fresh clone of Drum Track Studio.
# Downloads the third-party tools and builds the Python environment used for stem
# separation. Requires Python 3.10+ already installed and on PATH.
# Run: right-click Setup.ps1 > "Run with PowerShell" (or from a PowerShell prompt).

$ErrorActionPreference = 'Stop'
$Root   = $PSScriptRoot
$BinDir = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

function Get-FileIfMissing([string]$Url, [string]$Dest) {
    if (Test-Path -LiteralPath $Dest) {
        Write-Host "Already have $(Split-Path $Dest -Leaf)."
        return
    }
    Write-Host "Downloading $(Split-Path $Dest -Leaf)..."
    Invoke-WebRequest -Uri $Url -OutFile $Dest
}

# ---------- yt-dlp ----------
Get-FileIfMissing 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' `
    (Join-Path $BinDir 'yt-dlp.exe')

# ---------- ffmpeg + ffprobe ----------
$ffmpegExe = Join-Path $BinDir 'ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ffmpegExe)) {
    Write-Host 'Downloading ffmpeg (~100MB, one time)...'
    $ffZip  = Join-Path $env:TEMP 'dts_ffmpeg.zip'
    $ffTmp  = Join-Path $env:TEMP 'dts_ffmpeg_extract'
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

# ---------- Python venv + Demucs (CPU-only PyTorch) ----------
$EnvDir = Join-Path $Root 'env'
$VenvPy = Join-Path $EnvDir 'Scripts\python.exe'

if (-not (Test-Path -LiteralPath $VenvPy)) {
    Write-Host 'Creating Python virtual environment (requires Python 3.10+ on PATH)...'
    python -m venv $EnvDir
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create venv. Install Python 3.10+ from python.org and ensure "python" is on PATH.'
    }
}

Write-Host 'Installing CPU-only PyTorch + Demucs (large download, several minutes)...'
& $VenvPy -m pip install --upgrade pip
& $VenvPy -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu
& $VenvPy -m pip install demucs

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host 'Next: run Build-Exe.ps1 to compile DrumTrackStudio.exe, then double-click it to launch.' -ForegroundColor Green
Read-Host 'Press Enter to close'
