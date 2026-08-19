# Drum Track Studio
# Single-file WinForms app. The download/separation pipeline runs IN-PROCESS in a
# background PowerShell runspace (no child powershell.exe, no -ExecutionPolicy Bypass,
# no hidden shells) - external tools (yt-dlp/ffmpeg/python) are launched with
# CreateNoWindow so no console ever appears.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppVersion = '1.1.0'
# Set to 'youruser/DrumTrackStudio' to enable the startup update check (GitHub releases).
$RepoSlug   = ''

# ---------------------------------------------------------------- paths -----
# Resolve app root: works as a .ps1 and when compiled with PS2EXE
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
} else {
    $Root = Split-Path -Parent ([Environment]::GetCommandLineArgs()[0])
}

$BinDir = Join-Path $Root 'bin'
# Bundled runtime (installer builds) takes priority; dev venv is the fallback
$PythonExe = Join-Path $Root 'runtime\python.exe'
if (-not (Test-Path -LiteralPath $PythonExe)) {
    $PythonExe = Join-Path $Root 'env\Scripts\python.exe'
}

# Per-user output (writable even when installed under Program Files)
$OutBase      = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'DrumTrackStudio'
$DownloadsDir = Join-Path $OutBase 'Downloads'
$StemsDir     = Join-Path $OutBase 'Stems'
foreach ($d in @($DownloadsDir, $StemsDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# Rotating logs under %LOCALAPPDATA%
$LogDir = Join-Path $env:LOCALAPPDATA 'DrumTrackStudio\logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
$LogFile = Join-Path $LogDir ("DrumTrackStudio_{0:yyyyMMdd}.log" -f (Get-Date))

# ------------------------------------------------- shared state + pipeline -----
$Sync = [hashtable]::Synchronized(@{
    Status = ''; Done = $false; Success = $false; OutFile = ''; ErrorMsg = ''
    CurrentProcId = 0
})
$script:PipelinePS = $null

# The entire pipeline, executed inside a background runspace in THIS process.
# Uses: $Cfg (paths/url/mode), $Sync (status back to the UI thread).
$PipelineScript = {
    function Write-Log([string]$Text) {
        $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Text
        Add-Content -LiteralPath $Cfg.LogFile -Value $line -Encoding UTF8
    }
    function Set-Status([string]$Text) { $Sync.Status = $Text; Write-Log "STATUS: $Text" }
    function Fail([string]$Message) {
        Write-Log "ERROR: $Message"
        $Sync.ErrorMsg = $Message; $Sync.Success = $false; $Sync.Done = $true
        throw $Message
    }
    function Escape-Arg([string]$a) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"','\"') + '"' } else { $a }
    }
    # Launch a console tool with NO window, capture output, return exit code + stdout.
    function Invoke-Tool([string]$Exe, [string[]]$ToolArgs) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = ($ToolArgs | ForEach-Object { Escape-Arg $_ }) -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
        $psi.EnvironmentVariables['PATH'] = $Cfg.BinDir + ';' + $psi.EnvironmentVariables['PATH']
        $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        Write-Log ("RUN: {0} {1}" -f $Exe, $psi.Arguments)
        $p = [System.Diagnostics.Process]::Start($psi)
        $Sync.CurrentProcId = $p.Id
        # Async reads avoid stdout/stderr buffer deadlock
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $Sync.CurrentProcId = 0
        $stdout = $outTask.Result; $stderr = $errTask.Result
        if ($stdout) { Add-Content -LiteralPath $Cfg.LogFile -Value $stdout -Encoding UTF8 }
        if ($stderr) { Add-Content -LiteralPath $Cfg.LogFile -Value $stderr -Encoding UTF8 }
        [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout }
    }
    function Get-SampleRate([string]$Path) {
        $r = Invoke-Tool (Join-Path $Cfg.BinDir 'ffprobe.exe') @(
            '-v','error','-select_streams','a:0',
            '-show_entries','stream=sample_rate',
            '-of','default=noprint_wrappers=1:nokey=1', $Path)
        $line = ($r.StdOut -split "`r?`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
        if ($line) { [int]$line } else { 0 }
    }
    function Ensure-44100([string]$Path) {
        if ((Get-SampleRate $Path) -ne 44100) {
            Write-Log "Resampling to 44.1kHz: $Path"
            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path),
                   ([System.IO.Path]::GetFileNameWithoutExtension($Path) + '.44k.tmp.wav'))
            $r = Invoke-Tool (Join-Path $Cfg.BinDir 'ffmpeg.exe') @('-y','-i',$Path,'-ar','44100',$tmp)
            if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { Fail 'Resampling to 44.1kHz failed.' }
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
    }

    try {
        Write-Log "=== pipeline start (v$($Cfg.AppVersion)) URL=$($Cfg.Url) Mode=$($Cfg.Mode) ==="

        # ---------- 1. Download ----------
        Set-Status 'Downloading audio from YouTube...'
        $pathFile = Join-Path $env:TEMP ('dts_path_' + [guid]::NewGuid().ToString() + '.txt')
        $r = Invoke-Tool (Join-Path $Cfg.BinDir 'yt-dlp.exe') @(
            '-v',
            '-f','bestaudio','--extract-audio','--audio-format','wav','--audio-quality','0','--no-playlist',
            '--postprocessor-args','ffmpeg:-ar 44100',
            '--ffmpeg-location',$Cfg.BinDir,
            '-o',(Join-Path $Cfg.DownloadsDir '%(title)s.%(ext)s'),
            '--print-to-file','after_move:filepath',$pathFile,
            $Cfg.Url)
        if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pathFile)) {
            Fail 'Download failed. Check the URL and your internet connection.'
        }
        $file = Get-Content -LiteralPath $pathFile -Encoding UTF8 | Select-Object -Last 1
        Remove-Item -LiteralPath $pathFile -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $file)) { Fail 'Downloaded file not found.' }
        Write-Log "Saved: $file"
        Ensure-44100 $file

        if ($Cfg.Mode -eq 'audio') {
            $Sync.OutFile = $file; $Sync.Success = $true; $Sync.Done = $true
            Write-Log '=== pipeline done (audio) ==='
            return
        }

        # ---------- 2. Separate ----------
        $twoStem = if ($Cfg.Mode -eq 'karaoke') { 'vocals' } else { 'drums' }
        $stemOut = if ($Cfg.Mode -eq 'karaoke') { 'no_vocals.wav' } else { 'no_drums.wav' }
        $suffix  = if ($Cfg.Mode -eq 'karaoke') { 'Karaoke' } else { 'Drumless' }

        Set-Status 'Separating stems with AI... this can take several minutes (first run also downloads the model, ~300 MB)'
        $r = Invoke-Tool $Cfg.PythonExe @('-m','demucs','-o',$Cfg.StemsDir,'--two-stems',$twoStem,$file)
        if ($r.ExitCode -ne 0) { Fail 'Stem separation failed. See log for details.' }

        $title    = [System.IO.Path]::GetFileNameWithoutExtension($file)
        $stemFile = Join-Path (Join-Path (Join-Path $Cfg.StemsDir 'htdemucs') $title) $stemOut
        if (-not (Test-Path -LiteralPath $stemFile)) { Fail "Expected stem output not found: $stemFile" }
        Ensure-44100 $stemFile

        # ---------- 3. Copy to Downloads with a unique, USB-friendly name ----------
        Set-Status 'Finalizing...'
        $dest = Join-Path $Cfg.DownloadsDir ($title + ' - ' + $suffix + '.wav')
        Copy-Item -LiteralPath $stemFile -Destination $dest -Force
        if (-not (Test-Path -LiteralPath $dest)) { Fail 'Could not copy final file to Downloads.' }

        $Sync.OutFile = $dest; $Sync.Success = $true; $Sync.Done = $true
        Write-Log "=== pipeline done: $dest ==="
    }
    catch {
        if (-not $Sync.Done) {
            $Sync.ErrorMsg = $_.Exception.Message; $Sync.Success = $false; $Sync.Done = $true
        }
    }
}

# ---------------------------------------------------------------- GUI -----
$form = New-Object Windows.Forms.Form
$form.Text = "Drum Track Studio  v$AppVersion"
$form.Size = New-Object Drawing.Size(520, 360)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

$lbl = New-Object Windows.Forms.Label
$lbl.Text = 'YouTube URL:'
$lbl.Location = New-Object Drawing.Point(15, 15)
$lbl.AutoSize = $true
$form.Controls.Add($lbl)

$lblUpdate = New-Object Windows.Forms.Label
$lblUpdate.Text = ''
$lblUpdate.ForeColor = [Drawing.Color]::DarkGreen
$lblUpdate.Location = New-Object Drawing.Point(120, 15)
$lblUpdate.Size = New-Object Drawing.Size(370, 18)
$lblUpdate.TextAlign = 'TopRight'
$form.Controls.Add($lblUpdate)

$txt = New-Object Windows.Forms.TextBox
$txt.Location = New-Object Drawing.Point(15, 38)
$txt.Size = New-Object Drawing.Size(390, 24)
$form.Controls.Add($txt)

$btnPaste = New-Object Windows.Forms.Button
$btnPaste.Text = 'Paste'
$btnPaste.Location = New-Object Drawing.Point(415, 36)
$btnPaste.Size = New-Object Drawing.Size(75, 26)
$btnPaste.Add_Click({ try { $txt.Text = (Get-Clipboard -Raw).Trim() } catch {} })
$form.Controls.Add($btnPaste)

$grp = New-Object Windows.Forms.GroupBox
$grp.Text = 'What do you want?'
$grp.Location = New-Object Drawing.Point(15, 75)
$grp.Size = New-Object Drawing.Size(475, 112)
$form.Controls.Add($grp)

$r1 = New-Object Windows.Forms.RadioButton
$r1.Text = 'Audio Only  (WAV download, no separation)'
$r1.Location = New-Object Drawing.Point(15, 25); $r1.AutoSize = $true; $r1.Checked = $true
$grp.Controls.Add($r1)

$r2 = New-Object Windows.Forms.RadioButton
$r2.Text = 'Vocal Karaoke  (vocals removed - instrumental backing track)'
$r2.Location = New-Object Drawing.Point(15, 52); $r2.AutoSize = $true
$grp.Controls.Add($r2)

$r3 = New-Object Windows.Forms.RadioButton
$r3.Text = 'Drumless  (drums removed - play along on your kit)'
$r3.Location = New-Object Drawing.Point(15, 79); $r3.AutoSize = $true
$grp.Controls.Add($r3)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Text = 'Ready.'
$lblStatus.Location = New-Object Drawing.Point(15, 196)
$lblStatus.Size = New-Object Drawing.Size(475, 30)
$form.Controls.Add($lblStatus)

$btnGo = New-Object Windows.Forms.Button
$btnGo.Text = 'Download'
$btnGo.Location = New-Object Drawing.Point(15, 230)
$btnGo.Size = New-Object Drawing.Size(475, 38)
$btnGo.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$form.Controls.Add($btnGo)

$btnDl = New-Object Windows.Forms.Button
$btnDl.Text = 'Open Downloads folder'
$btnDl.Location = New-Object Drawing.Point(15, 278)
$btnDl.Size = New-Object Drawing.Size(152, 30)
$btnDl.Add_Click({ Start-Process explorer.exe $DownloadsDir })
$form.Controls.Add($btnDl)

$btnSt = New-Object Windows.Forms.Button
$btnSt.Text = 'Open Stems folder'
$btnSt.Location = New-Object Drawing.Point(177, 278)
$btnSt.Size = New-Object Drawing.Size(152, 30)
$btnSt.Add_Click({ Start-Process explorer.exe $StemsDir })
$form.Controls.Add($btnSt)

$btnLog = New-Object Windows.Forms.Button
$btnLog.Text = 'Open logs'
$btnLog.Location = New-Object Drawing.Point(339, 278)
$btnLog.Size = New-Object Drawing.Size(151, 30)
$btnLog.Add_Click({ Start-Process explorer.exe $LogDir })
$form.Controls.Add($btnLog)

# ------------------------------------------------------------- run logic -----
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

function Reset-UI {
    $timer.Stop()
    $btnGo.Enabled = $true
    $btnGo.Text = 'Download'
    if ($script:PipelinePS) { try { $script:PipelinePS.Dispose() } catch {}; $script:PipelinePS = $null }
}

$timer.Add_Tick({
    if (-not $Sync.Done) {
        if ($Sync.Status) { $lblStatus.Text = $Sync.Status }
        return
    }
    Reset-UI
    if ($Sync.Success) {
        $outFile = $Sync.OutFile
        $lblStatus.Text = 'Ready.'
        [Windows.Forms.MessageBox]::Show("Finished!`n`nSaved to:`n$outFile", 'Drum Track Studio',
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        if (Test-Path -LiteralPath $outFile) {
            Start-Process explorer.exe "/select,`"$outFile`""
        } else {
            Start-Process explorer.exe $DownloadsDir
        }
    } else {
        $msg = if ($Sync.ErrorMsg) { $Sync.ErrorMsg } else { 'Processing stopped unexpectedly.' }
        $lblStatus.Text = "Error: $msg"
        [Windows.Forms.MessageBox]::Show("Error: $msg`n`nDetails: use the 'Open logs' button.",
            'Drum Track Studio', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnGo.Add_Click({
    $url = $txt.Text.Trim()
    if (-not $url) {
        [Windows.Forms.MessageBox]::Show('Paste a YouTube URL first.', 'Drum Track Studio') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $BinDir 'yt-dlp.exe'))) {
        [Windows.Forms.MessageBox]::Show('yt-dlp.exe not found in the app''s bin folder. Reinstall the app.',
            'Drum Track Studio', 'OK', 'Error') | Out-Null
        return
    }
    $mode = 'audio'
    if ($r2.Checked) { $mode = 'karaoke' }
    elseif ($r3.Checked) { $mode = 'drumless' }
    if ($mode -ne 'audio' -and -not (Test-Path -LiteralPath $PythonExe)) {
        [Windows.Forms.MessageBox]::Show('The bundled audio engine (runtime\python.exe) was not found. Reinstall the app.',
            'Drum Track Studio', 'OK', 'Error') | Out-Null
        return
    }

    # reset shared state
    $Sync.Status = 'Starting...'; $Sync.Done = $false; $Sync.Success = $false
    $Sync.OutFile = ''; $Sync.ErrorMsg = ''; $Sync.CurrentProcId = 0

    $cfg = @{
        Url = $url; Mode = $mode; AppVersion = $AppVersion
        BinDir = $BinDir; PythonExe = $PythonExe
        DownloadsDir = $DownloadsDir; StemsDir = $StemsDir; LogFile = $LogFile
    }

    $btnGo.Enabled = $false
    $btnGo.Text = 'Working...'
    $lblStatus.Text = 'Starting...'

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Sync)
    $rs.SessionStateProxy.SetVariable('Cfg', $cfg)
    $script:PipelinePS = [powershell]::Create()
    $script:PipelinePS.Runspace = $rs
    [void]$script:PipelinePS.AddScript($PipelineScript.ToString())
    [void]$script:PipelinePS.BeginInvoke()
    $timer.Start()
})

# If the user closes mid-run, stop the worker and any tool it launched
$form.Add_FormClosing({
    param($s, $e)
    if ($script:PipelinePS -and -not $Sync.Done) {
        $ans = [Windows.Forms.MessageBox]::Show(
            'A download/separation is still running. Close anyway?',
            'Drum Track Studio', [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -eq [Windows.Forms.DialogResult]::No) { $e.Cancel = $true; return }
        if ($Sync.CurrentProcId -gt 0) {
            try { Stop-Process -Id $Sync.CurrentProcId -Force -ErrorAction SilentlyContinue } catch {}
        }
        try { $script:PipelinePS.Stop() } catch {}
    }
    $timer.Stop()
})

# ------------------------------------------------- non-blocking update check -----
if ($RepoSlug) {
    $UpdateSync = [hashtable]::Synchronized(@{ Message = '' })
    $urs = [runspacefactory]::CreateRunspace(); $urs.Open()
    $urs.SessionStateProxy.SetVariable('U', $UpdateSync)
    $urs.SessionStateProxy.SetVariable('Slug', $RepoSlug)
    $urs.SessionStateProxy.SetVariable('Cur', $AppVersion)
    $ups = [powershell]::Create(); $ups.Runspace = $urs
    [void]$ups.AddScript({
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Slug/releases/latest" -TimeoutSec 5 `
                   -Headers @{ 'User-Agent' = 'DrumTrackStudio' }
            $latest = ($rel.tag_name -replace '^v','')
            if ([version]$latest -gt [version]$Cur) {
                $U.Message = "Update available: v$latest (see GitHub releases)"
            }
        } catch { }
    })
    [void]$ups.BeginInvoke()
    $updTimer = New-Object Windows.Forms.Timer
    $updTimer.Interval = 2000
    $script:updChecks = 0
    $updTimer.Add_Tick({
        $script:updChecks++
        if ($UpdateSync.Message) { $lblUpdate.Text = $UpdateSync.Message; $updTimer.Stop() }
        elseif ($script:updChecks -gt 10) { $updTimer.Stop() }
    })
    $updTimer.Start()
}

Add-Content -LiteralPath $LogFile -Value ("[{0:HH:mm:ss}] App started v{1}" -f (Get-Date), $AppVersion) -Encoding UTF8
[void]$form.ShowDialog()
