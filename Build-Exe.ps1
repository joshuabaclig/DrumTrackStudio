# Compiles DrumTrackStudio.ps1 -> DrumTrackStudio.exe (no console window), with
# version metadata, an OPTIONAL Authenticode signing step, and a SHA256 checksum.
#
# Signing is entirely optional and skipped cleanly when no certificate is provided:
#   -CertThumbprint <thumbprint>   certificate in the CurrentUser\My store
#   or set env var DTS_CERT_THUMBPRINT
#   -TimestampUrl defaults to DigiCert's public timestamp server
param(
    [string]$Version = '1.3.0',
    [string]$CertThumbprint = $env:DTS_CERT_THUMBPRINT,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# PS2EXE: exact version from tools.lock.json, hash-verified, kept in build-tools\ - never
# Install-Module "latest" (a briefly-unlisted Gallery entry broke the v1.3.0 release build).
$pin = (Get-Content (Join-Path $Root 'tools.lock.json') -Raw | ConvertFrom-Json).buildTools.ps2exe
$modDir = Join-Path $Root "build-tools\ps2exe\$($pin.version)"
if (-not (Test-Path -LiteralPath (Join-Path $modDir 'ps2exe.psd1'))) {
    Write-Host "Downloading PS2EXE $($pin.version) (one time)..."
    $pkg = Join-Path ([IO.Path]::GetTempPath()) "ps2exe.$($pin.version).zip"   # .zip: Expand-Archive on PS 5.1 insists
    for ($try = 1; ; $try++) {
        try { Invoke-WebRequest -Uri $pin.url -OutFile $pkg -UseBasicParsing; break }
        catch {
            if ($try -ge 5) { throw "Could not download PS2EXE after $try tries: $($_.Exception.Message)" }
            Write-Host "  download failed ($($_.Exception.Message)) - retrying in $(10 * $try)s..."
            Start-Sleep -Seconds (10 * $try)
        }
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $pkg).Hash.ToLower()
    if ($actual -ne $pin.sha256.ToLower()) {
        throw "PS2EXE download does not match tools.lock.json (expected $($pin.sha256), got $actual)."
    }
    Expand-Archive -LiteralPath $pkg -DestinationPath $modDir -Force
    Remove-Item -LiteralPath $pkg -Force
}
Import-Module (Join-Path $modDir 'ps2exe.psd1') -Force

$exePath = Join-Path $Root 'DrumTrackStudio.exe'
$icon    = Join-Path $Root 'app.ico'
$params = @{
    inputFile   = Join-Path $Root 'DrumTrackStudio.ps1'
    outputFile  = $exePath
    noConsole   = $true
    title       = 'Drum Track Studio'
    product     = 'Drum Track Studio'
    description = 'Create drumless and karaoke tracks from YouTube audio'
    version     = $Version
}
if (Test-Path $icon) { $params.iconFile = $icon }

Invoke-ps2exe @params
Write-Host "Built: DrumTrackStudio.exe (v$Version)" -ForegroundColor Green

# ---------- optional signing ----------
if ($CertThumbprint) {
    $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if (-not $signtool) {
        # common Windows SDK locations
        $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending | Select-Object -First 1
    }
    if (-not $signtool) { throw 'CertThumbprint given but signtool.exe not found (install the Windows SDK).' }
    $st = if ($signtool -is [System.Management.Automation.CommandInfo]) { $signtool.Source } else { $signtool.FullName }
    & $st sign /sha1 $CertThumbprint /fd SHA256 /td SHA256 /tr $TimestampUrl $exePath
    if ($LASTEXITCODE -ne 0) { throw 'Signing failed.' }
    Write-Host 'Signed DrumTrackStudio.exe' -ForegroundColor Green
} else {
    Write-Host 'No certificate configured - skipping signing (expected for normal builds).'
}

# ---------- checksum ----------
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exePath).Hash.ToLower()
"$hash  DrumTrackStudio.exe" | Set-Content -LiteralPath (Join-Path $Root 'checksums.txt') -Encoding ascii
Write-Host "SHA256: $hash (written to checksums.txt)"
