Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Resolve app root in a way that works both as a .ps1 and when compiled with PS2EXE
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
} else {
    $Root = Split-Path -Parent ([Environment]::GetCommandLineArgs()[0])
}

$script:StatusFile = $null
$script:Proc       = $null

$form = New-Object Windows.Forms.Form
$form.Text = 'Drum Track Studio'
$form.Size = New-Object Drawing.Size(520, 360)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

$lbl = New-Object Windows.Forms.Label
$lbl.Text = 'YouTube URL:'
$lbl.Location = New-Object Drawing.Point(15, 15)
$lbl.AutoSize = $true
$form.Controls.Add($lbl)

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
$btnDl.Size = New-Object Drawing.Size(232, 30)
$btnDl.Add_Click({ Start-Process explorer.exe (Join-Path $Root 'Downloads') })
$form.Controls.Add($btnDl)

$btnSt = New-Object Windows.Forms.Button
$btnSt.Text = 'Open Stems folder'
$btnSt.Location = New-Object Drawing.Point(258, 278)
$btnSt.Size = New-Object Drawing.Size(232, 30)
$btnSt.Add_Click({ Start-Process explorer.exe (Join-Path $Root 'Stems') })
$form.Controls.Add($btnSt)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

function Reset-UI {
    $timer.Stop()
    $btnGo.Enabled = $true
    $btnGo.Text = 'Download'
    $script:Proc = $null
    if ($script:StatusFile -and (Test-Path -LiteralPath $script:StatusFile)) {
        Remove-Item -LiteralPath $script:StatusFile -ErrorAction SilentlyContinue
    }
    $script:StatusFile = $null
}

$timer.Add_Tick({
    $status = ''
    if ($script:StatusFile -and (Test-Path -LiteralPath $script:StatusFile)) {
        try { $status = (Get-Content -LiteralPath $script:StatusFile -Raw -ErrorAction Stop).Trim() } catch { $status = '' }
    }

    if ($status.StartsWith('Done|')) {
        $outFile = $status.Substring(5)
        $lblStatus.Text = 'Done.'
        Reset-UI
        [Windows.Forms.MessageBox]::Show("Finished!`n`nSaved to:`n$outFile", 'Drum Track Studio',
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        if (Test-Path -LiteralPath $outFile) {
            Start-Process explorer.exe "/select,`"$outFile`""
        } else {
            Start-Process explorer.exe (Join-Path $Root 'Downloads')
        }
        $lblStatus.Text = 'Ready.'
        return
    }
    if ($status.StartsWith('Error:')) {
        $lblStatus.Text = $status
        Reset-UI
        [Windows.Forms.MessageBox]::Show($status, 'Drum Track Studio',
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ($status) { $lblStatus.Text = $status }

    # Pipeline process died without reporting Done/Error
    if ($script:Proc -and $script:Proc.HasExited -and -not ($status.StartsWith('Done|') -or $status.StartsWith('Error:'))) {
        Start-Sleep -Milliseconds 300   # give a final status write a chance to land
        $late = ''
        if ($script:StatusFile -and (Test-Path -LiteralPath $script:StatusFile)) {
            try { $late = (Get-Content -LiteralPath $script:StatusFile -Raw).Trim() } catch {}
        }
        if (-not ($late.StartsWith('Done|') -or $late.StartsWith('Error:'))) {
            $lblStatus.Text = 'Error: processing stopped unexpectedly.'
            Reset-UI
            [Windows.Forms.MessageBox]::Show('Processing stopped unexpectedly. See the log in your TEMP folder for details.',
                'Drum Track Studio', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
})

$btnGo.Add_Click({
    $url = $txt.Text.Trim()
    if (-not $url) {
        [Windows.Forms.MessageBox]::Show('Paste a YouTube URL first.', 'Drum Track Studio') | Out-Null
        return
    }
    $mode = 'audio'
    if ($r2.Checked) { $mode = 'karaoke' }
    elseif ($r3.Checked) { $mode = 'drumless' }

    $script:StatusFile = Join-Path $env:TEMP ('dts_status_' + [guid]::NewGuid().ToString() + '.txt')
    Set-Content -LiteralPath $script:StatusFile -Value 'Starting...' -Encoding UTF8

    $btnGo.Enabled = $false
    $btnGo.Text = 'Working...'
    $lblStatus.Text = 'Starting...'

    $script:Proc = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass',
        '-File', ('"' + (Join-Path $Root 'run-pipeline.ps1') + '"'),
        '-Url', ('"' + $url + '"'),
        '-Mode', $mode,
        '-StatusFile', ('"' + $script:StatusFile + '"')
    )
    $timer.Start()
})

$form.Add_FormClosing({ $timer.Stop() })
[void]$form.ShowDialog()
