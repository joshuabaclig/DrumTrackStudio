# Builds the self-contained runtime/ folder the Windows installer bundles, so END
# USERS NEVER NEED PYTHON INSTALLED. Run on the build machine before Build-Installer.ps1.
#
#   runtime/  = embeddable CPython 3.12 (pinned + hash-verified, tools.lock.json)
#               + the pinned packages from requirements-app.lock.txt - the exact same
#               Python app and packages macOS/Linux run (drumtrackstudio/)
#   bin/      = ffmpeg.exe / ffprobe.exe / deno.exe, hash-verified
#
# Needs a host Python 3.12 (`py -3.12` or `python`): pip runs from it and installs
# into runtime\Lib\site-packages, so the runtime never bootstraps pip from the
# internet's "latest" get-pip.py.
#
#   -RunTests   afterwards, run the test suite with runtime\python.exe - i.e. test
#               the runtime that actually ships, after pruning (CI does this)
param(
    [switch]$SkipRuntime,   # only verify bin/ hashes
    [switch]$RunTests
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$lock = Get-Content (Join-Path $Root 'tools.lock.json') -Raw | ConvertFrom-Json

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }

# ---------- 1. verify vendored binaries against tools.lock.json ----------
$failed = $false
foreach ($tool in $lock.tools.PSObject.Properties) {
    $path = Join-Path $Root ('bin\' + $tool.Name)
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "MISSING: bin\$($tool.Name) - run Setup.ps1 (or download it from $($tool.Value.url))." -ForegroundColor Red
        $failed = $true; continue
    }
    $actual = Get-Sha256 $path
    if ($actual -ne $tool.Value.sha256.ToLower()) {
        Write-Host "HASH MISMATCH: bin\$($tool.Name)" -ForegroundColor Red
        Write-Host "  expected $($tool.Value.sha256)"
        Write-Host "  actual   $actual"
        Write-Host '  If you intentionally upgraded this tool, test the app end-to-end and update tools.lock.json.'
        $failed = $true
    } else {
        Write-Host "OK: bin\$($tool.Name) matches pinned hash." -ForegroundColor Green
    }
}
if ($failed) { throw 'Vendored binary verification failed - refusing to package.' }
if ($SkipRuntime) { return }

# ---------- 2. host Python (same minor version as the runtime) ----------
$pin = $lock.runtime.'python-embed'
$minor = ($pin.version -split '\.')[0..1] -join '.'          # e.g. 3.12
$hostExe = $null; $hostArgs = @()
foreach ($cand in @("py -$minor", 'python')) {
    $parts = $cand -split ' '
    $candArgs = @($parts | Select-Object -Skip 1)
    try {
        $v = & $parts[0] @candArgs -c 'import sys; print(*sys.version_info[:2], sep=chr(46))' 2>$null
        if ($LASTEXITCODE -eq 0 -and "$v".Trim() -eq $minor) { $hostExe = $parts[0]; $hostArgs = $candArgs; break }
    } catch { Write-Verbose "no $cand" }
}
if (-not $hostExe) { throw "A host Python $minor is required (install it from python.org; 'py -$minor' or 'python' must work)." }
function Invoke-HostPy {
    & $hostExe @hostArgs @args
    if ($LASTEXITCODE -ne 0) { throw "host python failed: $args" }
}
Write-Host "Host Python: $hostExe $hostArgs"

# ---------- 3. embeddable Python (pinned + verified), fresh every build ----------
$RuntimeDir = Join-Path $Root 'runtime'
$PyExe = Join-Path $RuntimeDir 'python.exe'
$Site = Join-Path $RuntimeDir 'Lib\site-packages'
if (Test-Path -LiteralPath $RuntimeDir) {
    Write-Host 'Removing the previous runtime/ (always rebuilt from scratch)...'
    Remove-Item -LiteralPath $RuntimeDir -Recurse -Force
}
$zipPath = Join-Path $env:TEMP "dts_python_embed_$($pin.version).zip"
if (-not (Test-Path -LiteralPath $zipPath) -or (Get-Sha256 $zipPath) -ne $pin.sha256) {
    Write-Host "Downloading embeddable Python $($pin.version)..."
    Invoke-WebRequest -Uri $pin.url -OutFile $zipPath -UseBasicParsing
}
if ((Get-Sha256 $zipPath) -ne $pin.sha256.ToLower()) { throw "Embeddable Python hash mismatch: $zipPath" }
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
Expand-Archive -Path $zipPath -DestinationPath $RuntimeDir -Force
New-Item -ItemType Directory -Force -Path $Site | Out-Null

# The ._pth file is the embeddable Python's whole sys.path (PYTHONPATH and the
# current directory are ignored). '..' is the install folder, which holds the
# drumtrackstudio package - that's what makes 'pythonw.exe -m drumtrackstudio' work.
$pth = Get-ChildItem $RuntimeDir -Filter 'python*._pth' | Select-Object -First 1
$zipName = (Get-ChildItem $RuntimeDir -Filter 'python*.zip' | Select-Object -First 1).Name
Set-Content -LiteralPath $pth.FullName -Encoding ascii -Value @($zipName, '.', 'Lib\site-packages', '..', 'import site')

# ---------- 4. pinned packages, installed by the host pip into the runtime ----------
Write-Host 'Installing pinned packages into runtime\Lib\site-packages (torch is large; several minutes)...'
Invoke-HostPy -m pip install --disable-pip-version-check --no-warn-script-location --no-compile `
    --target $Site `
    --index-url https://download.pytorch.org/whl/cpu `
    --extra-index-url https://pypi.org/simple `
    -r (Join-Path $Root 'requirements-app.lock.txt')
Remove-Item -LiteralPath (Join-Path $Site 'bin') -Recurse -Force -ErrorAction SilentlyContinue   # console-script shims

# ---------- 5. prune Qt modules the app never loads ----------
# The app needs QtCore/Gui/Widgets plus QtMultimedia (the trim editor's player,
# which uses Qt's bundled FFmpeg plugin), and QtTest (tiny) so -RunTests can test
# exactly this runtime. PySide6's Addons wheel also brings
# WebEngine, QML/Quick, 3D, PDF, charts and the Qt dev tools - several hundred MB
# the installer doesn't need. The -RunTests step below (and CI) prove the pruned
# runtime still runs the whole app, including audio playback.
$qt = Join-Path $Site 'PySide6'
$prune = @(
    'Qt6WebEngine*', 'QtWebEngine*', 'QtWebEngineProcess.exe', 'resources', 'translations\qtwebengine_locales',
    'qml', 'Qt6Quick*', 'QtQuick*', 'Qt6Qml*', 'QtQml*', 'Qt6LabsQml*',
    'Qt63D*', 'Qt3D*', 'Qt6Charts*', 'QtCharts*', 'Qt6DataVisualization*', 'QtDataVisualization*',
    'Qt6Graphs*', 'QtGraphs*', 'Qt6Pdf*', 'QtPdf*', 'Qt6Designer*', 'QtDesigner*', 'Qt6Location*', 'QtLocation*',
    'Qt6Positioning*', 'QtPositioning*', 'Qt6ShaderTools*', 'QtShaderTools*', 'Qt6Scxml*', 'QtScxml*',
    'Qt6StateMachine*', 'QtStateMachine*', 'Qt6RemoteObjects*', 'QtRemoteObjects*', 'Qt6Sensors*', 'QtSensors*',
    'Qt6SerialBus*', 'QtSerialBus*', 'Qt6SerialPort*', 'QtSerialPort*', 'Qt6WebChannel*', 'QtWebChannel*',
    'Qt6WebSockets*', 'QtWebSockets*', 'Qt6WebView*', 'QtWebView*', 'Qt6Bluetooth*', 'QtBluetooth*',
    'Qt6Nfc*', 'QtNfc*', 'Qt6SpatialAudio*', 'QtSpatialAudio*', 'Qt6TextToSpeech*', 'QtTextToSpeech*',
    'Qt6HttpServer*', 'QtHttpServer*', 'Qt6VirtualKeyboard*', 'Qt6Help*', 'QtHelp*', 'Qt6UiTools*', 'QtUiTools*',
    'Qt6Svg*', 'QtSvg*', 'Qt6OpenGL*', 'QtOpenGL*', 'opengl32sw.dll',
    'Qt6MultimediaQuick*', 'Qt6MultimediaWidgets*', 'QtMultimediaWidgets*',
    'Qt6Concurrent*', 'QtConcurrent*', 'Qt6Sql*', 'QtSql*', 'Qt6Xml*', 'QtXml*', 'Qt6Asyncio*', 'QtAsyncio*',
    'Qt6CanvasPainter*', 'QtCanvasPainter*', 'Qt6PrintSupport*', 'QtPrintSupport*',
    '*.exe', 'metatypes', 'include', 'typesystems', 'glue', 'scripts', 'doc', 'examples', 'support',
    'plugins\qmltooling', 'plugins\designer', 'plugins\sceneparsers', 'plugins\geometryloaders',
    'plugins\renderers', 'plugins\renderplugins', 'plugins\position', 'plugins\geoservices',
    'plugins\sqldrivers', 'plugins\webview', 'plugins\scxmldatamodel', 'plugins\sensors',
    'plugins\canbus', 'plugins\texttospeech', 'plugins\virtualkeyboard', 'plugins\assetimporters'
)
$before = (Get-ChildItem $qt -Recurse -File | Measure-Object Length -Sum).Sum
foreach ($pat in $prune) {
    Get-Item -Path (Join-Path $qt $pat) -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
}
# translations: keep only Qt's own (qt_*/qtbase_*/qtmultimedia_*), not the tools'
Get-ChildItem (Join-Path $qt 'translations') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(qt|qtbase|qtmultimedia)_' } | Remove-Item -Force
$after = (Get-ChildItem $qt -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("Pruned PySide6: {0:N0} MB -> {1:N0} MB" -f ($before / 1MB), ($after / 1MB))

# torch ships its C++ SDK too: ~770 MB of .lib files and ~30 MB of headers, used
# only to compile C++ against torch. Python loads the .dlls, never these.
$torch = Join-Path $Site 'torch'
$before = (Get-ChildItem $torch -Recurse -File | Measure-Object Length -Sum).Sum
Remove-Item -LiteralPath (Join-Path $torch 'include') -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $torch 'lib') -Filter '*.lib' -File -ErrorAction SilentlyContinue | Remove-Item -Force
$after = (Get-ChildItem $torch -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("Pruned torch C++ SDK: {0:N0} MB -> {1:N0} MB" -f ($before / 1MB), ($after / 1MB))

# ---------- 6. precompile (Program Files is read-only, so Python can't cache .pyc
# at run time - without this every launch, and every demucs/librosa child process,
# would recompile thousands of modules). unchecked-hash: the files never change
# after install (an upgrade replaces source and .pyc together). ----------
Write-Host 'Precompiling...'
& $PyExe -m compileall -q -j 0 --invalidation-mode unchecked-hash $Site (Join-Path $Root 'drumtrackstudio') (Join-Path $Root 'tools') | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'NOTE: some files did not compile (usually harmless test/template files in packages).' -ForegroundColor Yellow }

# ---------- 7. smoke test the runtime the way the installed app runs ----------
Write-Host 'Smoke testing the runtime...'
Push-Location $env:TEMP   # not the repo: prove '..' in the ._pth is what finds the app
try {
    $env:QT_QPA_PLATFORM = 'offscreen'
    & $PyExe -c @"
import sys, demucs.separate, librosa, yt_dlp, soundfile, numpy
from PySide6.QtWidgets import QApplication
from PySide6.QtMultimedia import QMediaPlayer, QAudioOutput
import drumtrackstudio, drumtrackstudio.gui, drumtrackstudio.editor, drumtrackstudio.pipeline
app = QApplication([])
p = QMediaPlayer(); p.setAudioOutput(QAudioOutput())
print('runtime OK: Python', sys.version.split()[0], '- drumtrackstudio', drumtrackstudio.__version__)
"@
    if ($LASTEXITCODE -ne 0) { throw 'Runtime smoke test failed - see the error above.' }
    & $PyExe -m drumtrackstudio --version
    if ($LASTEXITCODE -ne 0) { throw 'Runtime smoke test failed: python -m drumtrackstudio' }
    & $PyExe -m yt_dlp --version
    if ($LASTEXITCODE -ne 0) { throw 'Runtime smoke test failed: python -m yt_dlp' }
} finally {
    Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    Pop-Location
}

# ---------- 8. optional: the full test suite on the shipped runtime ----------
if ($RunTests) {
    # pytest goes in a side folder (never into runtime/, which ships); the embeddable
    # Python ignores PYTHONPATH, so the runner adds it to sys.path itself.
    $testDeps = Join-Path $Root 'build-tools\pytest'
    Invoke-HostPy -m pip install --disable-pip-version-check --target $testDeps --upgrade `
        -r (Join-Path $Root 'requirements-dev.lock.txt') --no-deps
    $env:QT_QPA_PLATFORM = 'offscreen'
    $env:QT_QPA_FONTDIR = Join-Path $env:WINDIR 'Fonts'
    try {
        & $PyExe -c "import sys; sys.path.insert(0, r'$testDeps'); import pytest; sys.exit(pytest.main(['-q', '-p', 'no:cacheprovider', r'$Root\tests']))"
        if ($LASTEXITCODE -ne 0) { throw 'Tests failed on the packaged runtime.' }
    } finally {
        Remove-Item Env:\QT_QPA_PLATFORM, Env:\QT_QPA_FONTDIR -ErrorAction SilentlyContinue
    }
}

$size = (Get-ChildItem $RuntimeDir -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host ("Runtime ready at: $RuntimeDir ({0:N0} MB)" -f ($size / 1MB)) -ForegroundColor Green
Write-Host 'Next: Build-Installer.ps1'
