param(
    [Parameter(Mandatory=$true)][string]$Url,
    [ValidateSet('audio','karaoke','drumless')][string]$Mode = 'audio',
    [Parameter(Mandatory=$true)][string]$StatusFile
)

# Runs hidden (no console). All progress goes to $StatusFile; details go to a log file.
$Root    = $PSScriptRoot
$env:PATH = (Join-Path $Root 'bin') + ';' + $env:PATH
$ytdlp   = Join-Path $Root 'bin\yt-dlp.exe'
$ffmpeg  = Join-Path $Root 'bin\ffmpeg.exe'
$ffprobe = Join-Path $Root 'bin\ffprobe.exe'
$python  = Join-Path $Root 'env\Scripts\python.exe'
$LogFile = [System.IO.Path]::ChangeExtension($StatusFile, '.log')

function Set-Status([string]$Text) {
    # Overwrite (not append): the GUI reads the whole file as the current status.
    Set-Content -LiteralPath $StatusFile -Value $Text -Encoding UTF8
}
function Write-Log([string]$Text) {
    Add-Content -LiteralPath $LogFile -Value $Text -Encoding UTF8
}
function Fail([string]$Message) {
    Write-Log "ERROR: $Message"
    Set-Status "Error: $Message"
    exit 1
}
function Get-SampleRate([string]$Path) {
    $sr = & $ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 $Path 2>$null
    return [int]($sr | Select-Object -First 1)
}
function Ensure-44100([string]$Path) {
    if ((Get-SampleRate $Path) -ne 44100) {
        Write-Log "Resampling to 44.1kHz: $Path"
        $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path),
               ([System.IO.Path]::GetFileNameWithoutExtension($Path) + '.44k.tmp.wav'))
        & $ffmpeg -y -i $Path -ar 44100 $tmp 2>&1 | Out-File -Append -LiteralPath $LogFile
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { Fail 'Resampling to 44.1kHz failed.' }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}

try {
    Write-Log "=== Drum Track Studio pipeline ==="
    Write-Log "URL : $Url"
    Write-Log "Mode: $Mode"

    # ---------- 1. Download ----------
    Set-Status 'Downloading audio from YouTube...'
    $pathFile = Join-Path $env:TEMP ('dts_path_' + [guid]::NewGuid().ToString() + '.txt')

    & $ytdlp -f bestaudio --extract-audio --audio-format wav --audio-quality 0 --no-playlist `
        --postprocessor-args "ffmpeg:-ar 44100" `
        --ffmpeg-location (Join-Path $Root 'bin') `
        -o (Join-Path $Root 'Downloads\%(title)s.%(ext)s') `
        --print-to-file after_move:filepath $pathFile `
        $Url 2>&1 | Out-File -Append -LiteralPath $LogFile

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pathFile)) {
        Fail 'Download failed. Check the URL and your internet connection.'
    }
    $file = Get-Content -LiteralPath $pathFile -Encoding UTF8 | Select-Object -Last 1
    Remove-Item -LiteralPath $pathFile -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $file)) { Fail 'Downloaded file not found.' }
    Write-Log "Saved: $file"
    Ensure-44100 $file

    if ($Mode -eq 'audio') {
        Set-Status ('Done|' + $file)
        exit 0
    }

    # ---------- 2. Separate ----------
    $twoStem = if ($Mode -eq 'karaoke') { 'vocals' } else { 'drums' }
    $stemOut = if ($Mode -eq 'karaoke') { 'no_vocals.wav' } else { 'no_drums.wav' }
    $suffix  = if ($Mode -eq 'karaoke') { 'Karaoke' } else { 'Drumless' }

    Set-Status 'Separating stems with AI... this can take several minutes (first run also downloads the model, ~300 MB)'
    $stemDir = Join-Path $Root 'Stems'
    & $python -m demucs -o $stemDir --two-stems $twoStem $file 2>&1 | Out-File -Append -LiteralPath $LogFile
    if ($LASTEXITCODE -ne 0) { Fail 'Stem separation failed. See log for details.' }

    # Demucs writes to Stems\htdemucs\<input filename without extension>\
    $title    = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $stemFile = Join-Path (Join-Path (Join-Path $stemDir 'htdemucs') $title) $stemOut
    if (-not (Test-Path -LiteralPath $stemFile)) { Fail "Expected stem output not found: $stemFile" }
    Ensure-44100 $stemFile

    # ---------- 3. Copy to Downloads with a unique, USB-friendly name ----------
    Set-Status 'Finalizing...'
    $dest = Join-Path (Join-Path $Root 'Downloads') ($title + ' - ' + $suffix + '.wav')
    Copy-Item -LiteralPath $stemFile -Destination $dest -Force
    if (-not (Test-Path -LiteralPath $dest)) { Fail 'Could not copy final file to Downloads.' }
    Write-Log "Final: $dest"

    Set-Status ('Done|' + $dest)
    exit 0
}
catch {
    Fail $_.Exception.Message
}
