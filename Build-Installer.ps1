# Builds the distributable installer:  dist\DrumTrackStudio-Setup-<version>.exe
# Order: Build-Runtime.ps1 -> Build-Exe.ps1 -> Build-Installer.ps1
# Requires Inno Setup 6 (https://jrsoftware.org/isinfo.php or `choco install innosetup`).
param(
    [string]$Version = '1.1.0',
    [string]$CertThumbprint = $env:DTS_CERT_THUMBPRINT,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

foreach ($req in @('DrumTrackStudio.exe', 'runtime\python.exe', 'bin\yt-dlp.exe', 'bin\ffmpeg.exe', 'bin\ffprobe.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $req))) {
        throw "Missing $req - run Build-Runtime.ps1 and Build-Exe.ps1 first."
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

$setup = Get-ChildItem (Join-Path $Root 'dist') -Filter 'DrumTrackStudio-Setup-*.exe' |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1

# optional signing of the installer itself
if ($CertThumbprint) {
    $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if (-not $signtool) {
        $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending | Select-Object -First 1
    }
    if ($signtool) {
        $st = if ($signtool -is [System.Management.Automation.CommandInfo]) { $signtool.Source } else { $signtool.FullName }
        & $st sign /sha1 $CertThumbprint /fd SHA256 /td SHA256 /tr $TimestampUrl $setup.FullName
        if ($LASTEXITCODE -ne 0) { throw 'Installer signing failed.' }
        Write-Host 'Signed installer.' -ForegroundColor Green
    }
} else {
    Write-Host 'No certificate configured - installer ships unsigned (expected; SmartScreen click-through documented in README).'
}

# checksums for the release
$lines = @()
foreach ($f in @($setup.FullName, (Join-Path $Root 'DrumTrackStudio.exe'))) {
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower()
    $lines += "$h  $(Split-Path $f -Leaf)"
}
$lines | Set-Content -LiteralPath (Join-Path $Root 'dist\checksums.txt') -Encoding ascii
Write-Host ''
Write-Host "Installer: $($setup.FullName)" -ForegroundColor Green
Write-Host 'Checksums: dist\checksums.txt (publish both with the GitHub release)'
