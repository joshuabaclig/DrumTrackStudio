# Drum Track Studio v1.2.0
# Single-file WinForms app. The download/separation pipeline runs IN-PROCESS in a
# background PowerShell runspace (no child powershell.exe, no -ExecutionPolicy Bypass,
# no hidden shells) - external tools (yt-dlp/ffmpeg/python) are launched with
# CreateNoWindow so no console ever appears.
#
# v1.2.0: Settings tab (format / sample rate / output dir, persisted to
# %APPDATA%\DrumTrackStudio\settings.json), live progress bar, clickable update
# notice, modernized flat styling.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppVersion = '1.2.0'
$RepoSlug   = 'joshuabaclig/DrumTrackStudio'

# ---------------------------------------------------------------- paths -----
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
} else {
    $Root = Split-Path -Parent ([Environment]::GetCommandLineArgs()[0])
}

$BinDir = Join-Path $Root 'bin'
$PythonExe = Join-Path $Root 'runtime\python.exe'
if (-not (Test-Path -LiteralPath $PythonExe)) {
    $PythonExe = Join-Path $Root 'env\Scripts\python.exe'
}

$OutBase          = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'DrumTrackStudio'
$DefaultDlDir     = Join-Path $OutBase 'Downloads'
$DefaultStemsDir  = Join-Path $OutBase 'Stems'

# Rotating logs under %LOCALAPPDATA%
$LogDir = Join-Path $env:LOCALAPPDATA 'DrumTrackStudio\logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
$LogFile = Join-Path $LogDir ("DrumTrackStudio_{0:yyyyMMdd}.log" -f (Get-Date))

# ---------------------------------------------------------------- settings -----
$SettingsDir  = Join-Path $env:APPDATA 'DrumTrackStudio'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$FormatChoices = @('best','aac','alac','flac','m4a','mp3','opus','vorbis','wav')
$RateDisplay = [ordered]@{
    '44100 (CD quality, default)' = '44100'
    '48000'                       = '48000'
    '22050'                       = '22050'
    'Keep source (no resampling)' = 'source'
}

function Get-DefaultSettings {
    @{ Format = 'wav'; SampleRate = '44100'; OutputDir = $DefaultDlDir; StemsDir = $DefaultStemsDir }
}
function Load-Settings {
    $s = Get-DefaultSettings
    try {
        if (Test-Path -LiteralPath $SettingsFile) {
            $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.Format -and ($FormatChoices -contains [string]$j.Format)) { $s.Format = [string]$j.Format }
            if ($j.SampleRate -and (@('44100','48000','22050','source') -contains [string]$j.SampleRate)) { $s.SampleRate = [string]$j.SampleRate }
            if ($j.OutputDir -and -not [string]::IsNullOrWhiteSpace([string]$j.OutputDir)) { $s.OutputDir = [string]$j.OutputDir }
            if ($j.StemsDir -and -not [string]::IsNullOrWhiteSpace([string]$j.StemsDir)) { $s.StemsDir = [string]$j.StemsDir }
        }
    } catch { $s = Get-DefaultSettings }   # corrupted file -> defaults, never fatal
    return $s
}
function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $SettingsDir)) { New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null }
        @{ Format = $script:Settings.Format; SampleRate = $script:Settings.SampleRate; OutputDir = $script:Settings.OutputDir; StemsDir = $script:Settings.StemsDir } |
            ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
        $lblSaved.Text = 'Settings saved.'
        $savedTimer.Stop(); $savedTimer.Start()
    } catch {
        $lblSaved.Text = 'Could not save settings (see logs).'
        Add-Content -LiteralPath $LogFile -Value ("[{0:HH:mm:ss}] Settings save failed: {1}" -f (Get-Date), $_.Exception.Message) -Encoding UTF8
    }
}

$script:Settings = Load-Settings
foreach ($d in @($script:Settings.OutputDir, $script:Settings.StemsDir)) {
    try { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } } catch {}
}

# ------------------------------------------------- shared state + pipeline -----
$Sync = [hashtable]::Synchronized(@{
    Status = ''; Done = $false; Success = $false; OutFile = ''; ErrorMsg = ''
    CurrentProcId = 0
    Progress = 0; ProgressMode = 'none'    # 'none' | 'percent' | 'marquee'
})
$script:PipelinePS = $null

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
    # Launch a console tool with NO window; stream stdout/stderr live (line-by-line to
    # the log, optionally parsing a progress percentage from stdout as it arrives).
    # Implementation note: uses polled ReadLineAsync instead of OutputDataReceived
    # events - scriptblock event handlers don't fire reliably inside a background
    # runspace while the pipeline is blocked, whereas polling Tasks is deterministic
    # and deadlock-free (both pipes are always being drained).
    function Invoke-Tool([string]$Exe, [string[]]$ToolArgs, [string]$ProgressPattern) {
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
        $sbOut = New-Object System.Text.StringBuilder
        $outTask = $p.StandardOutput.ReadLineAsync()
        $errTask = $p.StandardError.ReadLineAsync()
        $outDone = $false; $errDone = $false
        while (-not ($outDone -and $errDone)) {
            $any = $false
            if (-not $outDone -and $outTask.IsCompleted) {
                $line = $outTask.Result
                if ($null -eq $line) { $outDone = $true }
                else {
                    [void]$sbOut.AppendLine($line)
                    if ($line) { Add-Content -LiteralPath $Cfg.LogFile -Value $line -Encoding UTF8 }
                    if ($ProgressPattern -and $line -match $ProgressPattern) {
                        $Sync.Progress = [int][Math]::Min(100, [double]$matches[1])
                    }
                    $outTask = $p.StandardOutput.ReadLineAsync()
                }
                $any = $true
            }
            if (-not $errDone -and $errTask.IsCompleted) {
                $line = $errTask.Result
                if ($null -eq $line) { $errDone = $true }
                else {
                    if ($line) { Add-Content -LiteralPath $Cfg.LogFile -Value $line -Encoding UTF8 }
                    if ($ProgressPattern -and $line -match $ProgressPattern) {
                        $Sync.Progress = [int][Math]::Min(100, [double]$matches[1])
                    }
                    $errTask = $p.StandardError.ReadLineAsync()
                }
                $any = $true
            }
            if (-not $any) { Start-Sleep -Milliseconds 50 }
        }
        $p.WaitForExit()
        $Sync.CurrentProcId = 0
        [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $sbOut.ToString() }
    }
    function Get-SampleRate([string]$Path) {
        $r = Invoke-Tool (Join-Path $Cfg.BinDir 'ffprobe.exe') @(
            '-v','error','-select_streams','a:0',
            '-show_entries','stream=sample_rate',
            '-of','default=noprint_wrappers=1:nokey=1', $Path) $null
        $line = ($r.StdOut -split "`r?`n" | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
        if ($line) { [int]$line } else { 0 }
    }
    function Ensure-Rate([string]$Path, [string]$Rate) {
        if ($Rate -eq 'source') { return }
        $target = [int]$Rate
        if ((Get-SampleRate $Path) -ne $target) {
            Write-Log "Resampling to ${target}Hz: $Path"
            $ext = [System.IO.Path]::GetExtension($Path)
            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path),
                   ([System.IO.Path]::GetFileNameWithoutExtension($Path) + '.rate.tmp' + $ext))
            $r = Invoke-Tool (Join-Path $Cfg.BinDir 'ffmpeg.exe') @('-y','-i',$Path,'-ar',"$target",$tmp) $null
            if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { Fail 'Resampling failed.' }
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
    }
    # Convert a WAV stem to the user's chosen format. Returns the new file's path.
    function Convert-Stem([string]$SrcWav, [string]$DestNoExt, [string]$Format, [string]$Rate) {
        $extMap   = @{ mp3='mp3'; m4a='m4a'; aac='m4a'; alac='m4a'; flac='flac'; opus='opus'; vorbis='ogg' }
        $codecMap = @{
            mp3    = @('-c:a','libmp3lame','-q:a','0')
            m4a    = @('-c:a','aac','-b:a','256k')
            aac    = @('-c:a','aac','-b:a','256k')
            alac   = @('-c:a','alac')
            flac   = @('-c:a','flac')
            opus   = @('-c:a','libopus','-b:a','192k')
            vorbis = @('-c:a','libvorbis','-q:a','6')
        }
        $dest = $DestNoExt + '.' + $extMap[$Format]
        $ffArgs = @('-y','-i',$SrcWav) + $codecMap[$Format]
        if ($Rate -ne 'source') { $ffArgs += @('-ar',$Rate) }
        $ffArgs += $dest
        $r = Invoke-Tool (Join-Path $Cfg.BinDir 'ffmpeg.exe') $ffArgs $null
        if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $dest)) { Fail "Conversion to $Format failed." }
        return $dest
    }

    try {
        Write-Log "=== pipeline start (v$($Cfg.AppVersion)) URL=$($Cfg.Url) Mode=$($Cfg.Mode) Format=$($Cfg.Format) Rate=$($Cfg.SampleRate) ==="

        # ---------- 1. Download ----------
        Set-Status 'Downloading audio from YouTube...'
        $Sync.ProgressMode = 'percent'; $Sync.Progress = 0
        $pathFile = Join-Path $env:TEMP ('dts_path_' + [guid]::NewGuid().ToString() + '.txt')
        $dlArgs = @(
            '-v','--newline',
            '-f','bestaudio','--extract-audio','--audio-format',$Cfg.Format,'--audio-quality','0','--no-playlist')
        if ($Cfg.SampleRate -ne 'source') {
            $dlArgs += @('--postprocessor-args',"ffmpeg:-ar $($Cfg.SampleRate)")
        }
        $dlArgs += @(
            '--ffmpeg-location',$Cfg.BinDir,
            '-o',(Join-Path $Cfg.DownloadsDir '%(title)s.%(ext)s'),
            '--print-to-file','after_move:filepath',$pathFile,
            $Cfg.Url)
        $r = Invoke-Tool (Join-Path $Cfg.BinDir 'yt-dlp.exe') $dlArgs '\[download\]\s+(\d+(?:\.\d+)?)%'
        if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pathFile)) {
            Fail 'Download failed. Check the URL and your internet connection.'
        }
        $file = Get-Content -LiteralPath $pathFile -Encoding UTF8 | Select-Object -Last 1
        Remove-Item -LiteralPath $pathFile -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $file)) { Fail 'Downloaded file not found.' }
        Write-Log "Saved: $file"
        $Sync.Progress = 100
        Ensure-Rate $file $Cfg.SampleRate

        if ($Cfg.Mode -eq 'audio') {
            $Sync.OutFile = $file; $Sync.Success = $true; $Sync.Done = $true
            Write-Log '=== pipeline done (audio) ==='
            return
        }

        # ---------- 2. Separate (Demucs always outputs WAV stems) ----------
        $twoStem = if ($Cfg.Mode -eq 'karaoke') { 'vocals' } else { 'drums' }
        $stemOut = if ($Cfg.Mode -eq 'karaoke') { 'no_vocals.wav' } else { 'no_drums.wav' }
        $suffix  = if ($Cfg.Mode -eq 'karaoke') { 'Karaoke' } else { 'Drumless' }

        Set-Status 'Separating stems with AI... this can take several minutes (first run also downloads the model, ~300 MB)'
        $Sync.ProgressMode = 'marquee'
        $r = Invoke-Tool $Cfg.PythonExe @('-m','demucs','-o',$Cfg.StemsDir,'--two-stems',$twoStem,$file) $null
        if ($r.ExitCode -ne 0) { Fail 'Stem separation failed. See log for details.' }

        $title    = [System.IO.Path]::GetFileNameWithoutExtension($file)
        $stemFile = Join-Path (Join-Path (Join-Path $Cfg.StemsDir 'htdemucs') $title) $stemOut
        if (-not (Test-Path -LiteralPath $stemFile)) { Fail "Expected stem output not found: $stemFile" }
        Ensure-Rate $stemFile $Cfg.SampleRate

        # ---------- 3. Deliver in the configured format with a unique name ----------
        Set-Status 'Finalizing...'
        $destNoExt = Join-Path $Cfg.DownloadsDir ($title + ' - ' + $suffix)
        if ($Cfg.Format -eq 'wav' -or $Cfg.Format -eq 'best') {
            # Demucs stems are WAV already; 'best' has no meaning for stems - keep WAV.
            $dest = $destNoExt + '.wav'
            Copy-Item -LiteralPath $stemFile -Destination $dest -Force
            if (-not (Test-Path -LiteralPath $dest)) { Fail 'Could not copy final file to the output folder.' }
        } else {
            $dest = Convert-Stem $stemFile $destNoExt $Cfg.Format $Cfg.SampleRate
        }

        $Sync.OutFile = $dest; $Sync.Success = $true; $Sync.Done = $true
        Write-Log "=== pipeline done: $dest ==="
    }
    catch {
        if (-not $Sync.Done) {
            $Sync.ErrorMsg = $_.Exception.Message; $Sync.Success = $false; $Sync.Done = $true
        }
    }
}

# ---------------------------------------------------------------- theme -----
$ColBg     = [Drawing.Color]::FromArgb(248, 249, 250)
$ColText   = [Drawing.Color]::FromArgb(33, 37, 41)
$ColSubtle = [Drawing.Color]::FromArgb(108, 117, 125)
$ColAccent = [Drawing.Color]::FromArgb(198, 57, 43)
$ColAccentDark = [Drawing.Color]::FromArgb(160, 44, 33)
$ColBorder = [Drawing.Color]::FromArgb(206, 212, 218)
$FontBase  = New-Object Drawing.Font('Segoe UI', 10)
$FontSmall = New-Object Drawing.Font('Segoe UI', 8.5)
$FontBold  = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)

function Style-FlatButton($btn, [bool]$Primary = $false) {
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 1
    $btn.Cursor = 'Hand'
    if ($Primary) {
        $btn.BackColor = $ColAccent
        $btn.ForeColor = [Drawing.Color]::White
        $btn.FlatAppearance.BorderColor = $ColAccentDark
        $btn.FlatAppearance.MouseOverBackColor = $ColAccentDark
    } else {
        $btn.BackColor = [Drawing.Color]::White
        $btn.ForeColor = $ColText
        $btn.FlatAppearance.BorderColor = $ColBorder
        $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(233, 236, 239)
    }
}

# ---------------------------------------------------------------- GUI -----
$form = New-Object Windows.Forms.Form
$form.Text = "Drum Track Studio  v$AppVersion"
$form.ClientSize = New-Object Drawing.Size(560, 470)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = $ColBg
$form.ForeColor = $ColText
$form.Font = $FontBase

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(8, 8)
$tabs.Size = New-Object Drawing.Size(544, 454)
$form.Controls.Add($tabs)

$tabDl = New-Object Windows.Forms.TabPage
$tabDl.Text = 'Download'
$tabDl.BackColor = $ColBg
$tabs.TabPages.Add($tabDl)

$tabSet = New-Object Windows.Forms.TabPage
$tabSet.Text = 'Settings'
$tabSet.BackColor = $ColBg
$tabs.TabPages.Add($tabSet)

# ================= Download tab =================
$lbl = New-Object Windows.Forms.Label
$lbl.Text = 'YouTube URL:'
$lbl.Location = New-Object Drawing.Point(20, 16)
$lbl.AutoSize = $true
$tabDl.Controls.Add($lbl)

$lblUpdate = New-Object Windows.Forms.Label
$lblUpdate.Text = ''
$lblUpdate.ForeColor = $ColAccent
$lblUpdate.Location = New-Object Drawing.Point(150, 18)
$lblUpdate.Size = New-Object Drawing.Size(370, 18)
$lblUpdate.TextAlign = 'TopRight'
$lblUpdate.Font = $FontSmall
$lblUpdate.Cursor = 'Hand'
$lblUpdate.Add_Click({
    if ($lblUpdate.Text) { Start-Process "https://github.com/$RepoSlug/releases/latest" }
})
$tabDl.Controls.Add($lblUpdate)

$txt = New-Object Windows.Forms.TextBox
$txt.Location = New-Object Drawing.Point(20, 42)
$txt.Size = New-Object Drawing.Size(400, 26)
$tabDl.Controls.Add($txt)

$btnPaste = New-Object Windows.Forms.Button
$btnPaste.Text = 'Paste'
$btnPaste.Location = New-Object Drawing.Point(432, 40)
$btnPaste.Size = New-Object Drawing.Size(88, 28)
$btnPaste.Add_Click({ try { $txt.Text = (Get-Clipboard -Raw).Trim() } catch {} })
Style-FlatButton $btnPaste
$tabDl.Controls.Add($btnPaste)

$grp = New-Object Windows.Forms.GroupBox
$grp.Text = 'What do you want?'
$grp.Location = New-Object Drawing.Point(20, 82)
$grp.Size = New-Object Drawing.Size(500, 118)
$grp.ForeColor = $ColText
$tabDl.Controls.Add($grp)

$r1 = New-Object Windows.Forms.RadioButton
$r1.Text = 'Audio Only  (download, no separation)'
$r1.Location = New-Object Drawing.Point(18, 26); $r1.AutoSize = $true; $r1.Checked = $true
$grp.Controls.Add($r1)

$r2 = New-Object Windows.Forms.RadioButton
$r2.Text = 'Vocal Karaoke  (vocals removed - instrumental backing track)'
$r2.Location = New-Object Drawing.Point(18, 54); $r2.AutoSize = $true
$grp.Controls.Add($r2)

$r3 = New-Object Windows.Forms.RadioButton
$r3.Text = 'Drumless  (drums removed - play along on your kit)'
$r3.Location = New-Object Drawing.Point(18, 82); $r3.AutoSize = $true
$grp.Controls.Add($r3)

$bar = New-Object Windows.Forms.ProgressBar
$bar.Location = New-Object Drawing.Point(20, 214)
$bar.Size = New-Object Drawing.Size(500, 14)
$bar.Style = 'Continuous'
$bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 0
$bar.MarqueeAnimationSpeed = 30
$tabDl.Controls.Add($bar)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Text = 'Ready.'
$lblStatus.Location = New-Object Drawing.Point(20, 236)
$lblStatus.Size = New-Object Drawing.Size(500, 34)
$lblStatus.ForeColor = $ColSubtle
$lblStatus.Font = $FontSmall
$tabDl.Controls.Add($lblStatus)

$btnGo = New-Object Windows.Forms.Button
$btnGo.Text = 'Download'
$btnGo.Location = New-Object Drawing.Point(20, 276)
$btnGo.Size = New-Object Drawing.Size(500, 42)
$btnGo.Font = $FontBold
Style-FlatButton $btnGo $true
$tabDl.Controls.Add($btnGo)

$btnDl = New-Object Windows.Forms.Button
$btnDl.Text = 'Open output folder'
$btnDl.Location = New-Object Drawing.Point(20, 332)
$btnDl.Size = New-Object Drawing.Size(160, 32)
$btnDl.Add_Click({
    if (-not (Test-Path -LiteralPath $script:Settings.OutputDir)) {
        New-Item -ItemType Directory -Force -Path $script:Settings.OutputDir | Out-Null
    }
    Start-Process explorer.exe $script:Settings.OutputDir
})
Style-FlatButton $btnDl
$tabDl.Controls.Add($btnDl)

$btnSt = New-Object Windows.Forms.Button
$btnSt.Text = 'Open Stems folder'
$btnSt.Location = New-Object Drawing.Point(190, 332)
$btnSt.Size = New-Object Drawing.Size(160, 32)
$btnSt.Add_Click({
    if (-not (Test-Path -LiteralPath $script:Settings.StemsDir)) {
        New-Item -ItemType Directory -Force -Path $script:Settings.StemsDir | Out-Null
    }
    Start-Process explorer.exe $script:Settings.StemsDir
})
Style-FlatButton $btnSt
$tabDl.Controls.Add($btnSt)

$btnLog = New-Object Windows.Forms.Button
$btnLog.Text = 'Open logs'
$btnLog.Location = New-Object Drawing.Point(360, 332)
$btnLog.Size = New-Object Drawing.Size(160, 32)
$btnLog.Add_Click({ Start-Process explorer.exe $LogDir })
Style-FlatButton $btnLog
$tabDl.Controls.Add($btnLog)

# ================= Settings tab =================
$lblFmt = New-Object Windows.Forms.Label
$lblFmt.Text = 'Output format:'
$lblFmt.Location = New-Object Drawing.Point(20, 26)
$lblFmt.AutoSize = $true
$tabSet.Controls.Add($lblFmt)

$cmbFormat = New-Object Windows.Forms.ComboBox
$cmbFormat.DropDownStyle = 'DropDownList'
$cmbFormat.Location = New-Object Drawing.Point(220, 22)
$cmbFormat.Size = New-Object Drawing.Size(180, 26)
foreach ($f in $FormatChoices) { [void]$cmbFormat.Items.Add($f) }
$cmbFormat.SelectedItem = $script:Settings.Format
$tabSet.Controls.Add($cmbFormat)

$lblFmtNote = New-Object Windows.Forms.Label
$lblFmtNote.Text = 'Applies to all modes. Karaoke/Drumless are separated as WAV first, then converted, so non-WAV formats take a little longer. ("best" = keep whatever YouTube serves; Karaoke/Drumless stay WAV.)'
$lblFmtNote.Location = New-Object Drawing.Point(20, 56)
$lblFmtNote.Size = New-Object Drawing.Size(500, 34)
$lblFmtNote.ForeColor = $ColSubtle
$lblFmtNote.Font = $FontSmall
$tabSet.Controls.Add($lblFmtNote)

$lblRate = New-Object Windows.Forms.Label
$lblRate.Text = 'Sample rate:'
$lblRate.Location = New-Object Drawing.Point(20, 106)
$lblRate.AutoSize = $true
$tabSet.Controls.Add($lblRate)

$cmbRate = New-Object Windows.Forms.ComboBox
$cmbRate.DropDownStyle = 'DropDownList'
$cmbRate.Location = New-Object Drawing.Point(220, 102)
$cmbRate.Size = New-Object Drawing.Size(230, 26)
foreach ($k in $RateDisplay.Keys) { [void]$cmbRate.Items.Add($k) }
$cmbRate.SelectedItem = ($RateDisplay.Keys | Where-Object { $RateDisplay[$_] -eq $script:Settings.SampleRate } | Select-Object -First 1)
if (-not $cmbRate.SelectedItem) { $cmbRate.SelectedIndex = 0 }
$tabSet.Controls.Add($cmbRate)

$lblDir = New-Object Windows.Forms.Label
$lblDir.Text = 'Output folder (final tracks):'
$lblDir.Location = New-Object Drawing.Point(20, 150)
$lblDir.AutoSize = $true
$tabSet.Controls.Add($lblDir)

$txtDir = New-Object Windows.Forms.TextBox
$txtDir.Location = New-Object Drawing.Point(20, 176)
$txtDir.Size = New-Object Drawing.Size(400, 26)
$txtDir.ReadOnly = $true
$txtDir.Text = $script:Settings.OutputDir
$tabSet.Controls.Add($txtDir)

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object Drawing.Point(432, 174)
$btnBrowse.Size = New-Object Drawing.Size(88, 28)
Style-FlatButton $btnBrowse
$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where finished tracks are saved'
    if (Test-Path -LiteralPath $script:Settings.OutputDir) { $dlg.SelectedPath = $script:Settings.OutputDir }
    if ($dlg.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $script:Settings.OutputDir = $dlg.SelectedPath
        $txtDir.Text = $dlg.SelectedPath
        try { if (-not (Test-Path -LiteralPath $dlg.SelectedPath)) { New-Item -ItemType Directory -Force -Path $dlg.SelectedPath | Out-Null } } catch {}
        Save-Settings
    }
})
$tabSet.Controls.Add($btnBrowse)

$lblStemDir = New-Object Windows.Forms.Label
$lblStemDir.Text = 'Stems folder (raw separation output):'
$lblStemDir.Location = New-Object Drawing.Point(20, 216)
$lblStemDir.AutoSize = $true
$tabSet.Controls.Add($lblStemDir)

$txtStemDir = New-Object Windows.Forms.TextBox
$txtStemDir.Location = New-Object Drawing.Point(20, 242)
$txtStemDir.Size = New-Object Drawing.Size(400, 26)
$txtStemDir.ReadOnly = $true
$txtStemDir.Text = $script:Settings.StemsDir
$tabSet.Controls.Add($txtStemDir)

$btnStemBrowse = New-Object Windows.Forms.Button
$btnStemBrowse.Text = 'Browse...'
$btnStemBrowse.Location = New-Object Drawing.Point(432, 240)
$btnStemBrowse.Size = New-Object Drawing.Size(88, 28)
Style-FlatButton $btnStemBrowse
$btnStemBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose where raw separation stems are saved'
    if (Test-Path -LiteralPath $script:Settings.StemsDir) { $dlg.SelectedPath = $script:Settings.StemsDir }
    if ($dlg.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $script:Settings.StemsDir = $dlg.SelectedPath
        $txtStemDir.Text = $dlg.SelectedPath
        try { if (-not (Test-Path -LiteralPath $dlg.SelectedPath)) { New-Item -ItemType Directory -Force -Path $dlg.SelectedPath | Out-Null } } catch {}
        Save-Settings
    }
})
$tabSet.Controls.Add($btnStemBrowse)

$lblSaved = New-Object Windows.Forms.Label
$lblSaved.Text = ''
$lblSaved.Location = New-Object Drawing.Point(20, 284)
$lblSaved.Size = New-Object Drawing.Size(500, 18)
$lblSaved.ForeColor = $ColAccent
$lblSaved.Font = $FontSmall
$tabSet.Controls.Add($lblSaved)

$savedTimer = New-Object Windows.Forms.Timer
$savedTimer.Interval = 2500
$savedTimer.Add_Tick({ $lblSaved.Text = ''; $savedTimer.Stop() })

$cmbFormat.Add_SelectedIndexChanged({
    $script:Settings.Format = [string]$cmbFormat.SelectedItem
    Save-Settings
})
$cmbRate.Add_SelectedIndexChanged({
    $script:Settings.SampleRate = $RateDisplay[[string]$cmbRate.SelectedItem]
    Save-Settings
})

# ------------------------------------------------------------- run logic -----
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

function Reset-UI {
    $timer.Stop()
    $btnGo.Enabled = $true
    $btnGo.Text = 'Download'
    $Sync.ProgressMode = 'none'
    $bar.Style = 'Continuous'
    $bar.Value = 0
    if ($script:PipelinePS) { try { $script:PipelinePS.Dispose() } catch {}; $script:PipelinePS = $null }
}

$timer.Add_Tick({
    # progress bar
    switch ($Sync.ProgressMode) {
        'percent' {
            if ($bar.Style -ne [Windows.Forms.ProgressBarStyle]::Continuous) { $bar.Style = 'Continuous' }
            $v = [Math]::Min(100, [Math]::Max(0, [int]$Sync.Progress))
            if ($bar.Value -ne $v) { $bar.Value = $v }
        }
        'marquee' {
            if ($bar.Style -ne [Windows.Forms.ProgressBarStyle]::Marquee) { $bar.Style = 'Marquee' }
        }
        default {
            if ($bar.Style -ne [Windows.Forms.ProgressBarStyle]::Continuous) { $bar.Style = 'Continuous' }
            if ($bar.Value -ne 0 -and $Sync.Done) { $bar.Value = 0 }
        }
    }

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
            Start-Process explorer.exe $script:Settings.OutputDir
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
    try {
        if (-not (Test-Path -LiteralPath $script:Settings.OutputDir)) {
            New-Item -ItemType Directory -Force -Path $script:Settings.OutputDir | Out-Null
        }
    } catch {
        [Windows.Forms.MessageBox]::Show("Can't create the output folder:`n$($script:Settings.OutputDir)`n`nPick a different folder in Settings.",
            'Drum Track Studio', 'OK', 'Error') | Out-Null
        return
    }

    $Sync.Status = 'Starting...'; $Sync.Done = $false; $Sync.Success = $false
    $Sync.OutFile = ''; $Sync.ErrorMsg = ''; $Sync.CurrentProcId = 0
    $Sync.Progress = 0; $Sync.ProgressMode = 'none'

    $cfg = @{
        Url = $url; Mode = $mode; AppVersion = $AppVersion
        BinDir = $BinDir; PythonExe = $PythonExe
        DownloadsDir = $script:Settings.OutputDir; StemsDir = $script:Settings.StemsDir; LogFile = $LogFile
        Format = $script:Settings.Format; SampleRate = $script:Settings.SampleRate
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
                $U.Message = "Update available: v$latest - click here to download"
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
