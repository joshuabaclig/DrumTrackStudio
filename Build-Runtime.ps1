# Builds the self-contained runtime/ folder the installer bundles, so END USERS
# NEVER NEED PYTHON INSTALLED. Also verifies the vendored bin/ tools against the
# pinned SHA256 hashes in tools.lock.json. Run this on the build machine before
# Build-Installer.ps1.
#
#   runtime/  = embeddable CPython + pinned packages from requirements.lock.txt
#   bin/      = yt-dlp.exe / ffmpeg.exe / ffprobe.exe, hash-verified
param(
    [string]$PythonEmbedVersion = '3.10.11',
    [switch]$SkipRuntime   # only verify bin/ hashes
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# ---------- 1. verify vendored binaries against tools.lock.json ----------
$lock = Get-Content (Join-Path $Root 'tools.lock.json') -Raw | ConvertFrom-Json
$failed = $false
foreach ($tool in $lock.tools.PSObject.Properties) {
    $path = Join-Path $Root ('bin\' + $tool.Name)
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "MISSING: bin\$($tool.Name) - download it from $($tool.Value.source) and re-run." -ForegroundColor Red
        $failed = $true; continue
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
    if ($actual -ne $tool.Value.sha256.ToLower()) {
        Write-Host "HASH MISMATCH: bin\$($tool.Name)" -ForegroundColor Red
        Write-Host "  expected $($tool.Value.sha256)"
        Write-Host "  actual   $actual"
        Write-Host "  If you intentionally upgraded this tool, test the app end-to-end and update tools.lock.json."
        $failed = $true
    } else {
        Write-Host "OK: bin\$($tool.Name) matches pinned hash." -ForegroundColor Green
    }
}
if ($failed) { throw 'Vendored binary verification failed - refusing to package.' }

if ($SkipRuntime) { return }

# ---------- 2. build self-contained Python runtime ----------
$RuntimeDir = Join-Path $Root 'runtime'
$PyExe = Join-Path $RuntimeDir 'python.exe'

if (-not (Test-Path -LiteralPath $PyExe)) {
    Write-Host "Downloading embeddable Python $PythonEmbedVersion..."
    $zipUrl  = "https://www.python.org/ftp/python/$PythonEmbedVersion/python-$PythonEmbedVersion-embed-amd64.zip"
    $zipPath = Join-Path $env:TEMP 'dts_python_embed.zip'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $RuntimeDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    # enable site-packages in the embeddable distribution (._pth ships with 'import site' commented out)
    $pth = Get-ChildItem $RuntimeDir -Filter 'python*._pth' | Select-Object -First 1
    $content = Get-Content $pth.FullName
    $content = $content -replace '^#\s*import site$', 'import site'
    if ($content -notcontains 'import site') { $content += 'import site' }
    if ($content -notcontains 'Lib\site-packages') { $content += 'Lib\site-packages' }
    Set-Content -LiteralPath $pth.FullName -Value $content

    # bootstrap pip
    $getPip = Join-Path $env:TEMP 'get-pip.py'
    Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip
    & $PyExe $getPip --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { throw 'pip bootstrap failed.' }
    Remove-Item $getPip -Force -ErrorAction SilentlyContinue
}

Write-Host 'Installing pinned packages (torch is large; several minutes)...'
& $PyExe -m pip install --no-warn-script-location `
    --index-url https://download.pytorch.org/whl/cpu `
    --extra-index-url https://pypi.org/simple `
    -r (Join-Path $Root 'requirements.lock.txt')
if ($LASTEXITCODE -ne 0) { throw 'Package installation failed.' }

# smoke test: demucs importable?
& $PyExe -c "import demucs.separate; print('demucs OK')"
if ($LASTEXITCODE -ne 0) { throw 'Runtime smoke test failed - demucs not importable.' }

# smoke test: librosa importable? (BPM/key detection, tools\detect_features.py)
& $PyExe -c "import librosa; print('librosa OK')"
if ($LASTEXITCODE -ne 0) { throw 'Runtime smoke test failed - librosa not importable.' }

Write-Host ''
Write-Host "Runtime ready at: $RuntimeDir" -ForegroundColor Green
Write-Host 'Next: Build-Exe.ps1, then Build-Installer.ps1.'
