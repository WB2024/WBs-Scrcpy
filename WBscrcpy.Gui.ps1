# WBscrcpy.Gui.ps1 — WinForms front-end for WBscrcpy.Core.psm1
# Supports running as .ps1 OR as a ps2exe-built .exe.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve script root (works under ps2exe which lacks $PSScriptRoot)
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }

Import-Module (Join-Path $ScriptRoot "WBscrcpy.Core.psm1") -Force

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# --- State ----------------------------------------------------------------

$script:Presets    = Import-Presets
$script:RunningProc = $null

# --- Helpers --------------------------------------------------------------

function New-Label ($text, $x, $y, $w = 110) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = [Drawing.Point]::new($x, $y); $l.AutoSize = $true
    return $l
}
function New-Tooltip ($ctrl, $text) {
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.SetToolTip($ctrl, $text)
}

function Append-Log ([string]$msg) {
    if (-not $script:LogBox) { return }
    $script:LogBox.AppendText("[{0}] {1}{2}" -f (Get-Date -Format HH:mm:ss), $msg, [Environment]::NewLine)
}

function Show-Error ([string]$msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, "WBscrcpy", "OK", "Error") | Out-Null
}

function Refresh-DeviceList {
    $script:DeviceCombo.Items.Clear()
    if (-not (Test-CommandAvailable adb)) {
        Append-Log "adb not in PATH."
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
        if ($script:DeviceCombo.Items.Count -gt 0) {
            $script:DeviceCombo.SelectedIndex = 0
        }
        Append-Log "Refreshed devices: $($script:DeviceCombo.Items.Count) found."
    } catch {
        Append-Log "Device refresh failed: $_"
    }
}

function Refresh-PresetList {
    $script:PresetListBox.Items.Clear()
    foreach ($name in ($script:Presets.Keys | Sort-Object)) {
        [void]$script:PresetListBox.Items.Add($name)
    }
}

function Get-ConfigFromForm {
    $config = New-LaunchConfig
    $config.Mode = if ($script:UsbRadio.Checked) { "USB" } else { "Network" }
    $config.DisplayMode  = ($script:DisplayCombo.SelectedIndex + 1).ToString()
    $config.DeviceSerial = $script:DeviceCombo.Text
    $config.IP           = $script:IpBox.Text.Trim()
    $config.Port         = [int]$script:PortNum.Value
    $config.MaxFps       = [int]$script:FpsNum.Value
    $config.Bitrate      = if ($script:BitrateBox.Text.Trim()) { $script:BitrateBox.Text.Trim() } else { $null }
    $config.Codec        = if ($script:CodecCombo.SelectedIndex -le 0) { $null } else { $script:CodecCombo.SelectedItem.ToString() }
    $config.Density      = [int]$script:DensityNum.Value
    $config.ResetDensityOnExit = $script:ResetDensityChk.Checked
    $config.NoWakeLock   = $script:NoWakeChk.Checked
    return $config
}

function Set-FormFromConfig ($config) {
    $script:UsbRadio.Checked     = ($config.Mode -eq "USB")
    $script:NetworkRadio.Checked = ($config.Mode -eq "Network")
    $dm = 0
    [int]::TryParse($config.DisplayMode, [ref]$dm) | Out-Null
    if ($dm -ge 1 -and $dm -le 6) { $script:DisplayCombo.SelectedIndex = $dm - 1 }
    if ($config.DeviceSerial) { $script:DeviceCombo.Text = $config.DeviceSerial }
    if ($config.IP) { $script:IpBox.Text = $config.IP }
    if ($config.Port -gt 0) { $script:PortNum.Value = [Math]::Min(65535, [Math]::Max(1, $config.Port)) }
    $script:FpsNum.Value     = [Math]::Min(144, [Math]::Max(0, $config.MaxFps))
    $script:BitrateBox.Text  = if ($config.Bitrate) { $config.Bitrate } else { "" }
    $idx = @("(any)","h264","h265","av1").IndexOf((""+$config.Codec))
    $script:CodecCombo.SelectedIndex = if ($idx -lt 0) { 0 } else { $idx }
    $script:DensityNum.Value = [Math]::Min(640, [Math]::Max(0, $config.Density))
    $script:ResetDensityChk.Checked = [bool]$config.ResetDensityOnExit
    $script:NoWakeChk.Checked       = [bool]$config.NoWakeLock
    Update-NetworkEnabled
    Update-DensityEnabled
}

function Update-NetworkEnabled {
    $isNet = $script:NetworkRadio.Checked
    $script:IpBox.Enabled   = $isNet
    $script:PortNum.Enabled = $isNet
}

function Update-DensityEnabled {
    $isMode6 = ($script:DisplayCombo.SelectedIndex -eq 5)
    $script:DensityNum.Enabled      = $isMode6
    $script:ResetDensityChk.Enabled = $isMode6
}

# --- Build form -----------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "WBscrcpy — scrcpy Smart Launcher"
$form.Size = [Drawing.Size]::new(720, 640)
$form.StartPosition = "CenterScreen"
$form.MinimumSize   = [Drawing.Size]::new(640, 560)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$form.Controls.Add($tabs)

# ===== Launch tab =========================================================
$tabLaunch = New-Object System.Windows.Forms.TabPage
$tabLaunch.Text = "Launch"
$tabs.Controls.Add($tabLaunch)

# Connection group
$grpConn = New-Object System.Windows.Forms.GroupBox
$grpConn.Text = "Connection"
$grpConn.Location = [Drawing.Point]::new(10, 10)
$grpConn.Size     = [Drawing.Size]::new(680, 110)
$grpConn.Anchor   = "Top, Left, Right"
$tabLaunch.Controls.Add($grpConn)

$script:UsbRadio = New-Object System.Windows.Forms.RadioButton
$script:UsbRadio.Text = "USB"; $script:UsbRadio.Location = [Drawing.Point]::new(15, 25); $script:UsbRadio.AutoSize = $true; $script:UsbRadio.Checked = $true
$grpConn.Controls.Add($script:UsbRadio)

$script:NetworkRadio = New-Object System.Windows.Forms.RadioButton
$script:NetworkRadio.Text = "Network (Wi-Fi/Ethernet)"; $script:NetworkRadio.Location = [Drawing.Point]::new(80, 25); $script:NetworkRadio.AutoSize = $true
$grpConn.Controls.Add($script:NetworkRadio)

$grpConn.Controls.Add((New-Label "Device:" 15 55))
$script:DeviceCombo = New-Object System.Windows.Forms.ComboBox
$script:DeviceCombo.Location = [Drawing.Point]::new(80, 52); $script:DeviceCombo.Size = [Drawing.Size]::new(280, 22)
$script:DeviceCombo.DropDownStyle = "DropDown"
$grpConn.Controls.Add($script:DeviceCombo)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"; $btnRefresh.Location = [Drawing.Point]::new(370, 50); $btnRefresh.Size = [Drawing.Size]::new(80, 24)
$btnRefresh.Add_Click({ Refresh-DeviceList })
$grpConn.Controls.Add($btnRefresh)

$grpConn.Controls.Add((New-Label "IP:" 15 82))
$script:IpBox = New-Object System.Windows.Forms.TextBox
$script:IpBox.Location = [Drawing.Point]::new(80, 79); $script:IpBox.Size = [Drawing.Size]::new(160, 22); $script:IpBox.Text = "192.168.1.220"
$grpConn.Controls.Add($script:IpBox)

$grpConn.Controls.Add((New-Label "Port:" 250 82 40))
$script:PortNum = New-Object System.Windows.Forms.NumericUpDown
$script:PortNum.Location = [Drawing.Point]::new(290, 79); $script:PortNum.Size = [Drawing.Size]::new(70, 22)
$script:PortNum.Minimum = 1; $script:PortNum.Maximum = 65535; $script:PortNum.Value = 5555
$grpConn.Controls.Add($script:PortNum)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Connect TCP"; $btnConnect.Location = [Drawing.Point]::new(370, 78); $btnConnect.Size = [Drawing.Size]::new(100, 24)
$btnConnect.Add_Click({
    try {
        $serial = Connect-AdbNetworkDevice -IPAddress $script:IpBox.Text.Trim() -Port ([int]$script:PortNum.Value)
        Append-Log "Connected: $serial"
        Refresh-DeviceList
        $script:DeviceCombo.Text = $serial
    } catch { Show-Error $_.Exception.Message }
})
$grpConn.Controls.Add($btnConnect)

# Display + performance group
$grpDisp = New-Object System.Windows.Forms.GroupBox
$grpDisp.Text = "Display + Performance"
$grpDisp.Location = [Drawing.Point]::new(10, 130)
$grpDisp.Size     = [Drawing.Size]::new(680, 180)
$grpDisp.Anchor   = "Top, Left, Right"
$tabLaunch.Controls.Add($grpDisp)

$grpDisp.Controls.Add((New-Label "Display mode:" 15 25))
$script:DisplayCombo = New-Object System.Windows.Forms.ComboBox
$script:DisplayCombo.Location = [Drawing.Point]::new(120, 22); $script:DisplayCombo.Size = [Drawing.Size]::new(330, 22)
$script:DisplayCombo.DropDownStyle = "DropDownList"
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

$grpDisp.Controls.Add((New-Label "Max FPS (0=auto):" 15 55))
$script:FpsNum = New-Object System.Windows.Forms.NumericUpDown
$script:FpsNum.Location = [Drawing.Point]::new(140, 52); $script:FpsNum.Size = [Drawing.Size]::new(70, 22)
$script:FpsNum.Minimum = 0; $script:FpsNum.Maximum = 240; $script:FpsNum.Value = 0
$grpDisp.Controls.Add($script:FpsNum)

$grpDisp.Controls.Add((New-Label "Bitrate:" 230 55 50))
$script:BitrateBox = New-Object System.Windows.Forms.TextBox
$script:BitrateBox.Location = [Drawing.Point]::new(280, 52); $script:BitrateBox.Size = [Drawing.Size]::new(80, 22)
New-Tooltip $script:BitrateBox "e.g. 8M, 4M. Blank = scrcpy default."
$grpDisp.Controls.Add($script:BitrateBox)

$grpDisp.Controls.Add((New-Label "Codec:" 380 55 50))
$script:CodecCombo = New-Object System.Windows.Forms.ComboBox
$script:CodecCombo.Location = [Drawing.Point]::new(430, 52); $script:CodecCombo.Size = [Drawing.Size]::new(80, 22)
$script:CodecCombo.DropDownStyle = "DropDownList"
[void]$script:CodecCombo.Items.AddRange(@("(any)", "h264", "h265", "av1"))
$script:CodecCombo.SelectedIndex = 0
$grpDisp.Controls.Add($script:CodecCombo)

$grpDisp.Controls.Add((New-Label "Density (mode 6):" 15 90))
$script:DensityNum = New-Object System.Windows.Forms.NumericUpDown
$script:DensityNum.Location = [Drawing.Point]::new(140, 87); $script:DensityNum.Size = [Drawing.Size]::new(70, 22)
$script:DensityNum.Minimum = 0; $script:DensityNum.Maximum = 640; $script:DensityNum.Value = 0
$grpDisp.Controls.Add($script:DensityNum)

$script:ResetDensityChk = New-Object System.Windows.Forms.CheckBox
$script:ResetDensityChk.Text = "Reset density on exit"; $script:ResetDensityChk.Location = [Drawing.Point]::new(230, 89); $script:ResetDensityChk.AutoSize = $true
$grpDisp.Controls.Add($script:ResetDensityChk)

$script:NoWakeChk = New-Object System.Windows.Forms.CheckBox
$script:NoWakeChk.Text = "Skip stay-awake (no wake lock)"; $script:NoWakeChk.Location = [Drawing.Point]::new(15, 120); $script:NoWakeChk.AutoSize = $true
$grpDisp.Controls.Add($script:NoWakeChk)

# Action buttons
$btnLaunch = New-Object System.Windows.Forms.Button
$btnLaunch.Text = "Launch scrcpy"; $btnLaunch.Location = [Drawing.Point]::new(15, 150); $btnLaunch.Size = [Drawing.Size]::new(140, 28)
$btnLaunch.BackColor = [Drawing.Color]::FromArgb(0, 120, 215); $btnLaunch.ForeColor = [Drawing.Color]::White
$grpDisp.Controls.Add($btnLaunch)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop running scrcpy"; $btnStop.Location = [Drawing.Point]::new(165, 150); $btnStop.Size = [Drawing.Size]::new(140, 28)
$btnStop.Enabled = $false
$grpDisp.Controls.Add($btnStop)

# Log box
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = "Log"
$grpLog.Location = [Drawing.Point]::new(10, 320)
$grpLog.Size     = [Drawing.Size]::new(680, 240)
$grpLog.Anchor   = "Top, Bottom, Left, Right"
$tabLaunch.Controls.Add($grpLog)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true; $script:LogBox.ScrollBars = "Vertical"; $script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:LogBox.Location = [Drawing.Point]::new(10, 20)
$script:LogBox.Size     = [Drawing.Size]::new(660, 210)
$script:LogBox.Anchor   = "Top, Bottom, Left, Right"
$grpLog.Controls.Add($script:LogBox)

# ===== Presets tab =======================================================
$tabPresets = New-Object System.Windows.Forms.TabPage
$tabPresets.Text = "Presets"
$tabs.Controls.Add($tabPresets)

$tabPresets.Controls.Add((New-Label "Saved presets:" 10 12 100))
$script:PresetListBox = New-Object System.Windows.Forms.ListBox
$script:PresetListBox.Location = [Drawing.Point]::new(10, 35)
$script:PresetListBox.Size     = [Drawing.Size]::new(300, 400)
$script:PresetListBox.Anchor   = "Top, Bottom, Left"
$tabPresets.Controls.Add($script:PresetListBox)

$btnLoadPreset = New-Object System.Windows.Forms.Button
$btnLoadPreset.Text = "Load into form"; $btnLoadPreset.Location = [Drawing.Point]::new(330, 35); $btnLoadPreset.Size = [Drawing.Size]::new(140, 28)
$btnLoadPreset.Add_Click({
    $sel = $script:PresetListBox.SelectedItem
    if (-not $sel) { return }
    $cfg = New-LaunchConfig
    Copy-PresetToConfig -Config $cfg -Preset $script:Presets[$sel]
    Set-FormFromConfig $cfg
    Append-Log "Loaded preset '$sel' into form."
    $tabs.SelectedTab = $tabLaunch
})
$tabPresets.Controls.Add($btnLoadPreset)

$btnSavePreset = New-Object System.Windows.Forms.Button
$btnSavePreset.Text = "Save form as..."; $btnSavePreset.Location = [Drawing.Point]::new(330, 70); $btnSavePreset.Size = [Drawing.Size]::new(140, 28)
$btnSavePreset.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Preset name:", "Save preset", "")
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    try {
        Save-PresetFromConfig -Presets $script:Presets -Name $name -Config (Get-ConfigFromForm)
        Refresh-PresetList
        Append-Log "Saved preset '$name'."
    } catch { Show-Error $_.Exception.Message }
})
$tabPresets.Controls.Add($btnSavePreset)

$btnDeletePreset = New-Object System.Windows.Forms.Button
$btnDeletePreset.Text = "Delete selected"; $btnDeletePreset.Location = [Drawing.Point]::new(330, 105); $btnDeletePreset.Size = [Drawing.Size]::new(140, 28)
$btnDeletePreset.Add_Click({
    $sel = $script:PresetListBox.SelectedItem
    if (-not $sel) { return }
    $r = [System.Windows.Forms.MessageBox]::Show("Delete preset '$sel'?", "Confirm", "YesNo", "Question")
    if ($r -ne "Yes") { return }
    Remove-Preset -Presets $script:Presets -Name $sel
    Refresh-PresetList
    Append-Log "Deleted preset '$sel'."
})
$tabPresets.Controls.Add($btnDeletePreset)

# Need Microsoft.VisualBasic for InputBox
Add-Type -AssemblyName Microsoft.VisualBasic

# ===== Health tab ========================================================
$tabHealth = New-Object System.Windows.Forms.TabPage
$tabHealth.Text = "Health"
$tabs.Controls.Add($tabHealth)

$btnHealth = New-Object System.Windows.Forms.Button
$btnHealth.Text = "Run health check"; $btnHealth.Location = [Drawing.Point]::new(10, 10); $btnHealth.Size = [Drawing.Size]::new(160, 28)
$tabHealth.Controls.Add($btnHealth)

$lvHealth = New-Object System.Windows.Forms.ListView
$lvHealth.Location = [Drawing.Point]::new(10, 50)
$lvHealth.Size     = [Drawing.Size]::new(680, 460)
$lvHealth.Anchor   = "Top, Bottom, Left, Right"
$lvHealth.View = "Details"; $lvHealth.FullRowSelect = $true; $lvHealth.GridLines = $true
[void]$lvHealth.Columns.Add("Check", 200)
[void]$lvHealth.Columns.Add("Status", 80)
[void]$lvHealth.Columns.Add("Detail", 380)
$tabHealth.Controls.Add($lvHealth)

$btnHealth.Add_Click({
    $lvHealth.Items.Clear()
    try {
        $results = Invoke-HealthCheck -IPAddress $script:IpBox.Text.Trim() -Port ([int]$script:PortNum.Value)
        foreach ($r in $results) {
            $li = New-Object System.Windows.Forms.ListViewItem $r.Name
            [void]$li.SubItems.Add($r.Status)
            [void]$li.SubItems.Add($r.Detail)
            switch ($r.Status) {
                "Ok"   { $li.BackColor = [Drawing.Color]::FromArgb(220, 255, 220) }
                "Warn" { $li.BackColor = [Drawing.Color]::FromArgb(255, 245, 200) }
                "Fail" { $li.BackColor = [Drawing.Color]::FromArgb(255, 220, 220) }
            }
            [void]$lvHealth.Items.Add($li)
        }
    } catch { Show-Error $_.Exception.Message }
})

# --- Wire events ----------------------------------------------------------

$script:UsbRadio.Add_CheckedChanged({ Update-NetworkEnabled; Refresh-DeviceList })
$script:NetworkRadio.Add_CheckedChanged({ Update-NetworkEnabled; Refresh-DeviceList })
$script:DisplayCombo.Add_SelectedIndexChanged({ Update-DensityEnabled })

$btnLaunch.Add_Click({
    try {
        $cfg = Get-ConfigFromForm
        if ($cfg.Mode -eq "Network" -and -not (Test-IPv4 $cfg.IP)) { throw "Invalid IP." }
        if ($cfg.DisplayMode -eq "6" -and ($cfg.Density -lt 120 -or $cfg.Density -gt 640)) {
            throw "Display mode 6 requires Density 120-640."
        }
        if ($cfg.Mode -eq "USB" -and [string]::IsNullOrWhiteSpace($cfg.DeviceSerial)) {
            $usb = Resolve-UsbDevice -RequestedSerial $null
            if ($usb -is [string]) { $cfg.DeviceSerial = $usb }
            else { throw "Multiple USB devices; pick one in the Device dropdown." }
        }
        Append-Log "Launching scrcpy..."
        $script:RunningProc = Invoke-Scrcpy -Config $cfg -Logger { param($m) $form.Invoke([Action]{ Append-Log $m }) } -NoWait
        if ($script:RunningProc) {
            $btnStop.Enabled = $true
            $btnLaunch.Enabled = $false
            # Poll for exit on background timer
            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 800
            $timer.Add_Tick({
                if (-not $script:RunningProc -or $script:RunningProc.HasExited) {
                    $timer.Stop()
                    Append-Log "scrcpy exited (code $($script:RunningProc.ExitCode))."
                    $script:RunningProc = $null
                    $btnStop.Enabled = $false
                    $btnLaunch.Enabled = $true
                    # Run cleanup deferred (wake lock + density reset already wrapped in Invoke-Scrcpy finally)
                }
            })
            $timer.Start()
        }
    } catch {
        Show-Error $_.Exception.Message
        Append-Log "ERROR: $($_.Exception.Message)"
    }
})

$btnStop.Add_Click({
    if ($script:RunningProc -and -not $script:RunningProc.HasExited) {
        try { $script:RunningProc.Kill() } catch {}
        Append-Log "Sent kill to scrcpy."
    }
})

# --- Initial state --------------------------------------------------------

Update-NetworkEnabled
Update-DensityEnabled
Refresh-PresetList
Refresh-DeviceList

if (-not (Test-CommandAvailable adb))    { Append-Log "WARNING: adb not in PATH." }
if (-not (Test-CommandAvailable scrcpy)) { Append-Log "WARNING: scrcpy not in PATH." }

[void]$form.ShowDialog()
