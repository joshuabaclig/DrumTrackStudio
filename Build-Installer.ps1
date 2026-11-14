# Builds the distributable installer:  dist\DrumTrackStudio-Setup-<version>.exe
# Order: Setup.ps1 (fetches bin\) -> Build-Runtime.ps1 -> Build-Installer.ps1
# Requires Inno Setup 6 (https://jrsoftware.org/isinfo.php; preinstalled on GitHub's
# windows-2025 runners).
param(
    [string]$Version = '',   # default: drumtrackstudio\__init__.py's __version__
    [string]$CertThumbprint = $env:DTS_CERT_THUMBPRINT,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

$appVersion = [regex]::Match((Get-Content (Join-Path $Root 'drumtrackstudio\__init__.py') -Raw),
                             "__version__ = '([^']+)'").Groups[1].Value
if (-not $Version) { $Version = $appVersion }
if ($Version -ne $appVersion) { throw "Version $Version doesn't match drumtrackstudio\__init__.py ($appVersion)." }

foreach ($req in @('runtime\python.exe', 'runtime\pythonw.exe', 'bin\ffmpeg.exe', 'bin\ffprobe.exe', 'bin\deno.exe',
                   'drumtrackstudio\__main__.py', 'tools\detect_features.py')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $req))) {
        throw "Missing $req - run Setup.ps1 and Build-Runtime.ps1 first."
    }
}

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
    $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup (ISCC.exe) not found - install Inno Setup 6.' }
} else { $iscc = $iscc.Source }

& $iscc "/DMyAppVersion=$Version" (Join-Path $Root 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed.' }

$setup = Get-Item (Join-Path $Root "dist\DrumTrackStudio-Setup-$Version.exe")

# optional signing of the installer (skipped cleanly when no certificate is configured)
if ($CertThumbprint) {
    $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if (-not $signtool) {
        $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending | Select-Object -First 1
    }
    if (-not $signtool) { throw 'CertThumbprint given but signtool.exe not found (install the Windows SDK).' }
    $st = if ($signtool -is [System.Management.Automation.CommandInfo]) { $signtool.Source } else { $signtool.FullName }
    & $st sign /sha1 $CertThumbprint /fd SHA256 /td SHA256 /tr $TimestampUrl $setup.FullName
    if ($LASTEXITCODE -ne 0) { throw 'Installer signing failed.' }
    Write-Host 'Signed installer.' -ForegroundColor Green
} else {
    Write-Host 'No certificate configured - installer ships unsigned (expected; SmartScreen click-through documented in README).'
}

$h = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup.FullName).Hash.ToLower()
"$h  $($setup.Name)" | Set-Content -LiteralPath (Join-Path $Root 'dist\checksums.txt') -Encoding ascii
Write-Host ''
Write-Host ("Installer: $($setup.FullName) ({0:N0} MB)" -f ($setup.Length / 1MB)) -ForegroundColor Green
Write-Host 'Checksums: dist\checksums.txt (publish both with the GitHub release)'
