# DEVELOPER setup on Windows - the counterpart of setup.sh on macOS/Linux. End users
# should install the packaged installer from the GitHub Releases page instead: it
# bundles everything and needs no Python.
#
# Fetches the pinned ffmpeg/ffprobe/deno into bin/ (hash-checked against
# tools.lock.json) and builds the env/ venv with Python 3.12 and the same pinned
# packages every OS uses (requirements-app.lock.txt + requirements-dev.lock.txt).
# Afterwards:   env\Scripts\python -m drumtrackstudio          (the app)
#               env\Scripts\python -m pytest                   (the tests)
# Needs Python 3.12 from python.org (the 'py' launcher it installs is used).
#   -BinOnly   just fetch/verify bin\ (what the CI installer build needs)
param([switch]$NoPause, [switch]$BinOnly)

$ErrorActionPreference = 'Stop'
$Root   = $PSScriptRoot
$BinDir = Join-Path $Root 'bin'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$lock = Get-Content (Join-Path $Root 'tools.lock.json') -Raw | ConvertFrom-Json

function Save-Url([string]$Url, [string]$Dest) {
    for ($i = 1; $i -le 4; $i++) {
        try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing; return }
        catch { if ($i -eq 4) { throw }; Write-Host "  retrying ($($_.Exception.Message))"; Start-Sleep -Seconds (5 * $i) }
    }
}
function Expand-Tool([string]$ZipUrl, [string[]]$Names) {
    $zip = Join-Path $env:TEMP ('dts_' + [guid]::NewGuid() + '.zip')
    $tmp = Join-Path $env:TEMP ('dts_' + [guid]::NewGuid())
    try {
        Save-Url $ZipUrl $zip
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        foreach ($n in $Names) {
            $found = Get-ChildItem -Path $tmp -Recurse -Filter $n | Select-Object -First 1
            if (-not $found) { throw "$n not found in $ZipUrl" }
            Copy-Item $found.FullName (Join-Path $BinDir $n) -Force
        }
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- pinned third-party binaries (urls from tools.lock.json) ----------
foreach ($group in @(@{ Names = @('ffmpeg.exe', 'ffprobe.exe'); Key = 'ffmpeg.exe' },
                     @{ Names = @('deno.exe'); Key = 'deno.exe' })) {
    $missing = @($group.Names | Where-Object { -not (Test-Path -LiteralPath (Join-Path $BinDir $_)) })
    if ($missing) {
        Write-Host "Downloading $($group.Names -join ' + ') (one time)..."
        Expand-Tool $lock.tools.($group.Key).url $group.Names
    } else {
        Write-Host "Already have $($group.Names -join ' + ')."
    }
}
foreach ($tool in $lock.tools.PSObject.Properties) {
    $path = Join-Path $BinDir $tool.Name
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower() -ne $tool.Value.sha256.ToLower()) {
        Write-Host "NOTE: bin\$($tool.Name) is not the pinned version in tools.lock.json." -ForegroundColor Yellow
        Write-Host '      (Probably left over from an older pin: delete it and re-run Setup.ps1.)'
    }
}
# yt-dlp is a pinned Python package now (requirements-app.lock.txt); an old bin\yt-dlp.exe is unused
Remove-Item (Join-Path $BinDir 'yt-dlp.exe') -Force -ErrorAction SilentlyContinue
if ($BinOnly) { return }

# ---------- dev venv: Python 3.12, same pins as every other OS ----------
$EnvDir = Join-Path $Root 'env'
$VenvPy = Join-Path $EnvDir 'Scripts\python.exe'
if (Test-Path -LiteralPath $VenvPy) {
    $v = & $VenvPy -c 'import sys; print(*sys.version_info[:2], sep=chr(46))'
    if ("$v".Trim() -ne '3.12') {
        Write-Host "env\ uses Python $v - rebuilding it with 3.12..."
        Remove-Item -LiteralPath $EnvDir -Recurse -Force
    }
}
if (-not (Test-Path -LiteralPath $VenvPy)) {
    Write-Host 'Creating the Python 3.12 virtual environment...'
    & py -3.12 -m venv $EnvDir
    if ($LASTEXITCODE -ne 0) { throw 'Could not create env\ - install Python 3.12 from python.org (it includes the "py" launcher).' }
}

Write-Host 'Installing pinned packages (torch is large; several minutes the first time)...'
& $VenvPy -m pip install --disable-pip-version-check --quiet --upgrade pip
& $VenvPy -m pip install --disable-pip-version-check --index-url https://download.pytorch.org/whl/cpu `
    --extra-index-url https://pypi.org/simple `
    -r (Join-Path $Root 'requirements-app.lock.txt') -r (Join-Path $Root 'requirements-dev.lock.txt')
if ($LASTEXITCODE -ne 0) { throw 'Package installation failed.' }

& $VenvPy -c 'import demucs.separate, librosa, yt_dlp, PySide6.QtMultimedia, pytest'
if ($LASTEXITCODE -ne 0) { throw 'Smoke test failed - a package did not import. See the output above.' }

Write-Host ''
Write-Host 'Dev setup complete.' -ForegroundColor Green
Write-Host '  Run the app:     env\Scripts\python -m drumtrackstudio'
Write-Host '  Run the tests:   env\Scripts\python -m pytest'
Write-Host '  Build installer: Build-Runtime.ps1, then Build-Installer.ps1'
if (-not $NoPause -and [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') { Read-Host 'Press Enter to close' | Out-Null }
