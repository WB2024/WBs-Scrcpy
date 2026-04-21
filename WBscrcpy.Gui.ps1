# WBscrcpy.Gui.ps1 — WinForms front-end for WBscrcpy.Core.psm1
# Compatible with Windows PowerShell 5.1+ and ps2exe-compiled .exe.
# NOTE: No Set-StrictMode / global ErrorActionPreference — WinForms init must not throw to the host.

[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Resolve script root — works as .ps1 and as ps2exe-compiled .exe.
# $PSScriptRoot is empty in ps2exe; MyInvocation.MyCommand may lack .Path.
# ---------------------------------------------------------------------------
$ScriptRoot = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ScriptRoot = $PSScriptRoot
    }
    elseif ($MyInvocation.MyCommand.PSObject.Properties['Path'] -and
            -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
}
catch { }

if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    try {
        $ScriptRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }
    catch {
        $ScriptRoot = (Get-Location).Path
    }
}

# Load shared logic.  -DisableNameChecking suppresses the unapproved-verb warning dialog.
Import-Module (Join-Path $ScriptRoot "WBscrcpy.Core.psm1") -Force -DisableNameChecking

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:Presets     = Import-Presets
$script:RunningProc = $null
$script:LogBox      = $null      # populated during form build; guard before use

# ---------------------------------------------------------------------------
# Small UI helpers
# ---------------------------------------------------------------------------
function New-Label {
    param([string]$Text, [int]$X, [int]$Y)
    $l          = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize = $true
    return $l
}

function New-Tooltip {
    param($Ctrl, [string]$Text)
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.SetToolTip($Ctrl, $Text)
}

function Append-Log {
    param([string]$msg)
    if (-not $script:LogBox) { return }
    # String concatenation — avoids any -f format-string edge cases under ps2exe.
    $line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $msg + [Environment]::NewLine
    $script:LogBox.AppendText($line)
}

function Show-Error {
    param([string]$msg)
    [void][System.Windows.Forms.MessageBox]::Show($msg, "WBscrcpy", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

# ---------------------------------------------------------------------------
# Device list
# ---------------------------------------------------------------------------
function Refresh-DeviceList {
    $script:DeviceCombo.Items.Clear()
    if (-not (Test-CommandAvailable "adb")) {
        Append-Log "adb not in PATH — install Android Platform Tools."
        return
    }
    try {
        Start-AdbServer
        $devs = Get-AdbDevice
        foreach ($d in $devs) {
            if ($d.State -ne "device") { continue }
            if ($script:NetworkRadio.Checked -and -not $d.IsTcp) { continue }
            if ($script:UsbRadio.Checked     -and      $d.IsTcp) { continue }
            [void]$script:DeviceCombo.Items.Add($d.Serial)
        }
        if ($script:DeviceCombo.Items.Count -gt 0) { $script:DeviceCombo.SelectedIndex = 0 }
        Append-Log ("Refreshed: " + $script:DeviceCombo.Items.Count + " device(s) found.")
    }
    catch {
        Append-Log ("Device refresh error: " + $_.Exception.Message)
    }
}

function Refresh-PresetList {
    $script:PresetListBox.Items.Clear()
    foreach ($name in ($script:Presets.Keys | Sort-Object)) {
        [void]$script:PresetListBox.Items.Add($name)
    }
}

# ---------------------------------------------------------------------------
# Config <-> form
# ---------------------------------------------------------------------------
function Get-ConfigFromForm {
    $config              = New-LaunchConfig
    $config.Mode         = if ($script:UsbRadio.Checked) { "USB" } else { "Network" }
    $config.DisplayMode  = ($script:DisplayCombo.SelectedIndex + 1).ToString()
    $config.DeviceSerial = $script:DeviceCombo.Text.Trim()
    $config.IP           = $script:IpBox.Text.Trim()
    $config.Port         = [int]$script:PortNum.Value
    $config.MaxFps       = [int]$script:FpsNum.Value
    $config.Bitrate      = if ($script:BitrateBox.Text.Trim()) { $script:BitrateBox.Text.Trim() } else { $null }

    if ($script:CodecCombo.SelectedIndex -le 0) {
        $config.Codec = $null
    } else {
        $config.Codec = $script:CodecCombo.SelectedItem.ToString()
    }

    $config.Density            = [int]$script:DensityNum.Value
    $config.ResetDensityOnExit = $script:ResetDensityChk.Checked
    $config.NoWakeLock         = $script:NoWakeChk.Checked
    return $config
}

function Set-FormFromConfig {
    param([PSCustomObject]$Config)
    $script:UsbRadio.Checked     = ($Config.Mode -eq "USB")
    $script:NetworkRadio.Checked = ($Config.Mode -eq "Network")

    $dm = 0
    if ([int]::TryParse($Config.DisplayMode, [ref]$dm) -and $dm -ge 1 -and $dm -le 6) {
        $script:DisplayCombo.SelectedIndex = $dm - 1
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.DeviceSerial)) { $script:DeviceCombo.Text = $Config.DeviceSerial }
    if (-not [string]::IsNullOrWhiteSpace($Config.IP))           { $script:IpBox.Text        = $Config.IP }
    if ($Config.Port -gt 0) { $script:PortNum.Value = [Math]::Min(65535, [Math]::Max(1, $Config.Port)) }

    $script:FpsNum.Value    = [Math]::Min(240, [Math]::Max(0, $Config.MaxFps))
    $script:BitrateBox.Text = if ($Config.Bitrate) { $Config.Bitrate } else { "" }

    $codecOptions = @("(any)", "h264", "h265", "av1")
    $codecIdx     = [Array]::IndexOf($codecOptions, ("" + $Config.Codec))
    $script:CodecCombo.SelectedIndex = if ($codecIdx -lt 0) { 0 } else { $codecIdx }

    $script:DensityNum.Value        = [Math]::Min(640, [Math]::Max(0, $Config.Density))
    $script:ResetDensityChk.Checked = [bool]$Config.ResetDensityOnExit
    $script:NoWakeChk.Checked       = [bool]$Config.NoWakeLock

    Update-NetworkEnabled
    Update-DensityEnabled
}

function Update-NetworkEnabled {
    $isNet                  = $script:NetworkRadio.Checked
    $script:IpBox.Enabled   = $isNet
    $script:PortNum.Enabled = $isNet
}

function Update-DensityEnabled {
    $isMode6                        = ($script:DisplayCombo.SelectedIndex -eq 5)
    $script:DensityNum.Enabled      = $isMode6
    $script:ResetDensityChk.Enabled = $isMode6
}

# ---------------------------------------------------------------------------
# Build form
# ---------------------------------------------------------------------------
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "WBscrcpy - scrcpy Smart Launcher"
$form.Size          = New-Object System.Drawing.Size(720, 640)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize   = New-Object System.Drawing.Size(640, 560)

$tabs      = New-Object System.Windows.Forms.TabControl
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($tabs)

# ===== Launch tab ==========================================================
$tabLaunch      = New-Object System.Windows.Forms.TabPage
$tabLaunch.Text = "Launch"
$tabs.Controls.Add($tabLaunch)

# -- Connection group -------------------------------------------------------
$grpConn          = New-Object System.Windows.Forms.GroupBox
$grpConn.Text     = "Connection"
$grpConn.Location = New-Object System.Drawing.Point(10, 10)
$grpConn.Size     = New-Object System.Drawing.Size(680, 115)
$grpConn.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabLaunch.Controls.Add($grpConn)

$script:UsbRadio          = New-Object System.Windows.Forms.RadioButton
$script:UsbRadio.Text     = "USB"
$script:UsbRadio.Location = New-Object System.Drawing.Point(15, 25)
$script:UsbRadio.AutoSize = $true
$script:UsbRadio.Checked  = $true
$grpConn.Controls.Add($script:UsbRadio)

$script:NetworkRadio          = New-Object System.Windows.Forms.RadioButton
$script:NetworkRadio.Text     = "Network (Wi-Fi / Ethernet)"
$script:NetworkRadio.Location = New-Object System.Drawing.Point(80, 25)
$script:NetworkRadio.AutoSize = $true
$grpConn.Controls.Add($script:NetworkRadio)

$grpConn.Controls.Add((New-Label "Device:" 15 58))
$script:DeviceCombo               = New-Object System.Windows.Forms.ComboBox
$script:DeviceCombo.Location      = New-Object System.Drawing.Point(75, 55)
$script:DeviceCombo.Size          = New-Object System.Drawing.Size(285, 22)
$script:DeviceCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$grpConn.Controls.Add($script:DeviceCombo)

$btnRefresh          = New-Object System.Windows.Forms.Button
$btnRefresh.Text     = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(370, 53)
$btnRefresh.Size     = New-Object System.Drawing.Size(80, 26)
$btnRefresh.Add_Click({ Refresh-DeviceList })
$grpConn.Controls.Add($btnRefresh)

$grpConn.Controls.Add((New-Label "IP:" 15 85))
$script:IpBox          = New-Object System.Windows.Forms.TextBox
$script:IpBox.Location = New-Object System.Drawing.Point(75, 82)
$script:IpBox.Size     = New-Object System.Drawing.Size(165, 22)
$script:IpBox.Text     = "192.168.1.220"
$grpConn.Controls.Add($script:IpBox)

$grpConn.Controls.Add((New-Label "Port:" 250 85))
$script:PortNum         = New-Object System.Windows.Forms.NumericUpDown
$script:PortNum.Location = New-Object System.Drawing.Point(285, 82)
$script:PortNum.Size    = New-Object System.Drawing.Size(70, 22)
$script:PortNum.Minimum = 1
$script:PortNum.Maximum = 65535
$script:PortNum.Value   = 5555
$grpConn.Controls.Add($script:PortNum)

$btnConnect          = New-Object System.Windows.Forms.Button
$btnConnect.Text     = "Connect TCP"
$btnConnect.Location = New-Object System.Drawing.Point(370, 80)
$btnConnect.Size     = New-Object System.Drawing.Size(105, 26)
$btnConnect.Add_Click({
    try {
        $serial = Connect-AdbNetworkDevice -IPAddress $script:IpBox.Text.Trim() -Port ([int]$script:PortNum.Value)
        Append-Log ("Connected: " + $serial)
        Refresh-DeviceList
        $script:DeviceCombo.Text = $serial
    }
    catch { Show-Error $_.Exception.Message }
})
$grpConn.Controls.Add($btnConnect)

# -- Display + performance group -------------------------------------------
$grpDisp          = New-Object System.Windows.Forms.GroupBox
$grpDisp.Text     = "Display + Performance"
$grpDisp.Location = New-Object System.Drawing.Point(10, 135)
$grpDisp.Size     = New-Object System.Drawing.Size(680, 185)
$grpDisp.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabLaunch.Controls.Add($grpDisp)

$grpDisp.Controls.Add((New-Label "Display mode:" 15 27))
$script:DisplayCombo               = New-Object System.Windows.Forms.ComboBox
$script:DisplayCombo.Location      = New-Object System.Drawing.Point(120, 24)
$script:DisplayCombo.Size          = New-Object System.Drawing.Size(335, 22)
$script:DisplayCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:DisplayCombo.Items.AddRange(@(
    "1. Normal window",
    "2. Fullscreen",
    "3. Fullscreen + Screen OFF",
    "4. Borderless fullscreen",
    "5. High quality (1080p / 8M)",
    "6. Custom density + Fullscreen + Screen OFF"
))
$script:DisplayCombo.SelectedIndex = 0
$grpDisp.Controls.Add($script:DisplayCombo)

$grpDisp.Controls.Add((New-Label "Max FPS (0=auto):" 15 57))
$script:FpsNum         = New-Object System.Windows.Forms.NumericUpDown
$script:FpsNum.Location = New-Object System.Drawing.Point(140, 54)
$script:FpsNum.Size    = New-Object System.Drawing.Size(70, 22)
$script:FpsNum.Minimum = 0
$script:FpsNum.Maximum = 240
$script:FpsNum.Value   = 0
$grpDisp.Controls.Add($script:FpsNum)

$grpDisp.Controls.Add((New-Label "Bitrate:" 225 57))
$script:BitrateBox          = New-Object System.Windows.Forms.TextBox
$script:BitrateBox.Location = New-Object System.Drawing.Point(275, 54)
$script:BitrateBox.Size     = New-Object System.Drawing.Size(80, 22)
New-Tooltip $script:BitrateBox "e.g. 8M, 4M. Blank = scrcpy default."
$grpDisp.Controls.Add($script:BitrateBox)

$grpDisp.Controls.Add((New-Label "Codec:" 375 57))
$script:CodecCombo               = New-Object System.Windows.Forms.ComboBox
$script:CodecCombo.Location      = New-Object System.Drawing.Point(420, 54)
$script:CodecCombo.Size          = New-Object System.Drawing.Size(80, 22)
$script:CodecCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:CodecCombo.Items.AddRange(@("(any)", "h264", "h265", "av1"))
$script:CodecCombo.SelectedIndex = 0
$grpDisp.Controls.Add($script:CodecCombo)

$grpDisp.Controls.Add((New-Label "Density (mode 6):" 15 92))
$script:DensityNum          = New-Object System.Windows.Forms.NumericUpDown
$script:DensityNum.Location = New-Object System.Drawing.Point(145, 89)
$script:DensityNum.Size     = New-Object System.Drawing.Size(70, 22)
$script:DensityNum.Minimum  = 0
$script:DensityNum.Maximum  = 640
$script:DensityNum.Value    = 0
$grpDisp.Controls.Add($script:DensityNum)

$script:ResetDensityChk          = New-Object System.Windows.Forms.CheckBox
$script:ResetDensityChk.Text     = "Reset density on exit"
$script:ResetDensityChk.Location = New-Object System.Drawing.Point(230, 91)
$script:ResetDensityChk.AutoSize = $true
$grpDisp.Controls.Add($script:ResetDensityChk)

$script:NoWakeChk          = New-Object System.Windows.Forms.CheckBox
$script:NoWakeChk.Text     = "Skip stay-awake (no wake lock)"
$script:NoWakeChk.Location = New-Object System.Drawing.Point(15, 124)
$script:NoWakeChk.AutoSize = $true
$grpDisp.Controls.Add($script:NoWakeChk)

$btnLaunch           = New-Object System.Windows.Forms.Button
$btnLaunch.Text      = "Launch scrcpy"
$btnLaunch.Location  = New-Object System.Drawing.Point(15, 152)
$btnLaunch.Size      = New-Object System.Drawing.Size(140, 28)
$btnLaunch.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnLaunch.ForeColor = [System.Drawing.Color]::White
$grpDisp.Controls.Add($btnLaunch)

$btnStop          = New-Object System.Windows.Forms.Button
$btnStop.Text     = "Stop running scrcpy"
$btnStop.Location = New-Object System.Drawing.Point(165, 152)
$btnStop.Size     = New-Object System.Drawing.Size(145, 28)
$btnStop.Enabled  = $false
$grpDisp.Controls.Add($btnStop)

# -- Log group -------------------------------------------------------------
$grpLog          = New-Object System.Windows.Forms.GroupBox
$grpLog.Text     = "Log"
$grpLog.Location = New-Object System.Drawing.Point(10, 330)
$grpLog.Size     = New-Object System.Drawing.Size(680, 230)
$grpLog.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabLaunch.Controls.Add($grpLog)

$script:LogBox             = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline   = $true
$script:LogBox.ScrollBars  = [System.Windows.Forms.ScrollBars]::Vertical
$script:LogBox.ReadOnly    = $true
$script:LogBox.Font        = New-Object System.Drawing.Font("Consolas", 9)
$script:LogBox.Location    = New-Object System.Drawing.Point(8, 18)
$script:LogBox.Size        = New-Object System.Drawing.Size(662, 202)
$script:LogBox.Anchor      = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$grpLog.Controls.Add($script:LogBox)

# ===== Presets tab =========================================================
$tabPresets      = New-Object System.Windows.Forms.TabPage
$tabPresets.Text = "Presets"
$tabs.Controls.Add($tabPresets)

$tabPresets.Controls.Add((New-Label "Saved presets:" 10 12))

$script:PresetListBox          = New-Object System.Windows.Forms.ListBox
$script:PresetListBox.Location = New-Object System.Drawing.Point(10, 35)
$script:PresetListBox.Size     = New-Object System.Drawing.Size(300, 400)
$script:PresetListBox.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$tabPresets.Controls.Add($script:PresetListBox)

$btnLoadPreset          = New-Object System.Windows.Forms.Button
$btnLoadPreset.Text     = "Load into form"
$btnLoadPreset.Location = New-Object System.Drawing.Point(325, 35)
$btnLoadPreset.Size     = New-Object System.Drawing.Size(145, 28)
$btnLoadPreset.Add_Click({
    $sel = $script:PresetListBox.SelectedItem
    if (-not $sel) { return }
    try {
        $cfg = New-LaunchConfig
        Copy-PresetToConfig -Config $cfg -Preset $script:Presets[$sel]
        Set-FormFromConfig -Config $cfg
        Append-Log ("Loaded preset '" + $sel + "' into form.")
        $tabs.SelectedTab = $tabLaunch
    }
    catch { Show-Error $_.Exception.Message }
})
$tabPresets.Controls.Add($btnLoadPreset)

$btnSavePreset          = New-Object System.Windows.Forms.Button
$btnSavePreset.Text     = "Save form as..."
$btnSavePreset.Location = New-Object System.Drawing.Point(325, 72)
$btnSavePreset.Size     = New-Object System.Drawing.Size(145, 28)
$btnSavePreset.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Preset name:", "Save Preset", "")
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    try {
        Save-PresetFromConfig -Presets $script:Presets -Name $name -Config (Get-ConfigFromForm)
        Refresh-PresetList
        Append-Log ("Saved preset '" + $name + "'.")
    }
    catch { Show-Error $_.Exception.Message }
})
$tabPresets.Controls.Add($btnSavePreset)

$btnDeletePreset          = New-Object System.Windows.Forms.Button
$btnDeletePreset.Text     = "Delete selected"
$btnDeletePreset.Location = New-Object System.Drawing.Point(325, 109)
$btnDeletePreset.Size     = New-Object System.Drawing.Size(145, 28)
$btnDeletePreset.Add_Click({
    $sel = $script:PresetListBox.SelectedItem
    if (-not $sel) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        ("Delete preset '" + $sel + "'?"), "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Remove-Preset -Presets $script:Presets -Name $sel
    Refresh-PresetList
    Append-Log ("Deleted preset '" + $sel + "'.")
})
$tabPresets.Controls.Add($btnDeletePreset)

# ===== Health tab ==========================================================
$tabHealth      = New-Object System.Windows.Forms.TabPage
$tabHealth.Text = "Health"
$tabs.Controls.Add($tabHealth)

$btnHealth          = New-Object System.Windows.Forms.Button
$btnHealth.Text     = "Run health check"
$btnHealth.Location = New-Object System.Drawing.Point(10, 10)
$btnHealth.Size     = New-Object System.Drawing.Size(160, 28)
$tabHealth.Controls.Add($btnHealth)

$lvHealth              = New-Object System.Windows.Forms.ListView
$lvHealth.Location     = New-Object System.Drawing.Point(10, 50)
$lvHealth.Size         = New-Object System.Drawing.Size(680, 460)
$lvHealth.Anchor       = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lvHealth.View         = [System.Windows.Forms.View]::Details
$lvHealth.FullRowSelect = $true
$lvHealth.GridLines    = $true
[void]$lvHealth.Columns.Add("Check",  200)
[void]$lvHealth.Columns.Add("Status",  80)
[void]$lvHealth.Columns.Add("Detail", 380)
$tabHealth.Controls.Add($lvHealth)

$btnHealth.Add_Click({
    $lvHealth.Items.Clear()
    try {
        $results = Invoke-HealthCheck -IPAddress $script:IpBox.Text.Trim() -Port ([int]$script:PortNum.Value)
        foreach ($r in $results) {
            $li = New-Object System.Windows.Forms.ListViewItem($r.Name)
            [void]$li.SubItems.Add($r.Status)
            [void]$li.SubItems.Add($r.Detail)
            switch ($r.Status) {
                "Ok"   { $li.BackColor = [System.Drawing.Color]::FromArgb(220, 255, 220) }
                "Warn" { $li.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 200) }
                "Fail" { $li.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220) }
            }
            [void]$lvHealth.Items.Add($li)
        }
    }
    catch { Show-Error $_.Exception.Message }
})

# ---------------------------------------------------------------------------
# Wire up events
# ---------------------------------------------------------------------------
$script:UsbRadio.Add_CheckedChanged({
    if ($script:UsbRadio.Checked) { Update-NetworkEnabled; Refresh-DeviceList }
})
$script:NetworkRadio.Add_CheckedChanged({
    if ($script:NetworkRadio.Checked) { Update-NetworkEnabled; Refresh-DeviceList }
})
$script:DisplayCombo.Add_SelectedIndexChanged({ Update-DensityEnabled })

$btnLaunch.Add_Click({
    try {
        $cfg = Get-ConfigFromForm
        if ($cfg.Mode -eq "Network" -and -not (Test-IPv4 $cfg.IP)) {
            throw "Invalid IP address: " + $cfg.IP
        }
        if ($cfg.DisplayMode -eq "6" -and ($cfg.Density -lt 120 -or $cfg.Density -gt 640)) {
            throw "Display mode 6 requires Density 120-640."
        }
        if ($cfg.Mode -eq "USB" -and [string]::IsNullOrWhiteSpace($cfg.DeviceSerial)) {
            $usbResult = Resolve-UsbDevice -RequestedSerial $null
            if ($usbResult -is [string]) {
                $cfg.DeviceSerial = $usbResult
            }
            elseif ($usbResult.Count -eq 1) {
                $cfg.DeviceSerial = $usbResult[0].Serial
            }
            else {
                throw "Multiple USB devices detected. Select one from the Device list and try again."
            }
        }

        Append-Log "Launching scrcpy..."
        $btnLaunch.Enabled = $false
        $btnStop.Enabled   = $true

        $capturedForm = $form
        $script:RunningProc = Invoke-Scrcpy -Config $cfg -Logger {
            param($m)
            try { $capturedForm.Invoke([System.Action]{ Append-Log $m }) } catch {}
        } -NoWait

        if ($script:RunningProc) {
            $script:ExitTimer          = New-Object System.Windows.Forms.Timer
            $script:ExitTimer.Interval = 800
            $script:ExitTimer.Add_Tick({
                $proc = $script:RunningProc
                if ((-not $proc) -or $proc.HasExited) {
                    $script:ExitTimer.Stop()
                    $exitCode = if ($proc) { $proc.ExitCode } else { "n/a" }
                    Append-Log ("scrcpy exited (code " + $exitCode + ").")
                    $script:RunningProc = $null
                    $btnStop.Enabled   = $false
                    $btnLaunch.Enabled = $true
                }
            })
            $script:ExitTimer.Start()
        }
        else {
            $btnStop.Enabled   = $false
            $btnLaunch.Enabled = $true
        }
    }
    catch {
        $btnStop.Enabled   = $false
        $btnLaunch.Enabled = $true
        Show-Error $_.Exception.Message
        Append-Log ("ERROR: " + $_.Exception.Message)
    }
})

$btnStop.Add_Click({
    $proc = $script:RunningProc
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch {}
        Append-Log "Kill signal sent to scrcpy."
    }
})

# ---------------------------------------------------------------------------
# Initialise
# ---------------------------------------------------------------------------
Update-NetworkEnabled
Update-DensityEnabled
Refresh-PresetList
Refresh-DeviceList

if (-not (Test-CommandAvailable "scrcpy")) {
    Append-Log "WARNING: scrcpy not found in PATH."
}

[void]$form.ShowDialog()
