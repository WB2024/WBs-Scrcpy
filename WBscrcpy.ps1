# WBscrcpy.ps1 — CLI launcher (uses WBscrcpy.Core.psm1)

[CmdletBinding()]
param(
    [string]$DefaultIP = "192.168.1.220",
    [int]$DefaultPort = 5555,

    [ValidateSet("Interactive", "USB", "Network")]
    [string]$Mode = "Interactive",

    [ValidateSet("1", "2", "3", "4", "5", "6")]
    [string]$DisplayMode,

    [string]$DeviceSerial,
    [string]$IP,
    [int]$Port,

    [int]$MaxFps,
    [string]$Bitrate,

    [ValidateSet("h264", "h265", "av1")]
    [string]$Codec,

    [int]$Density,
    [switch]$ResetDensityOnExit,

    [string]$LoadPreset,
    [string]$SavePreset,
    [switch]$NoLaunch,
    [switch]$ListPresets,

    [switch]$HealthCheck,
    [switch]$NoWakeLock,
    [switch]$NoInteractiveTuning,
    [switch]$Gui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "WBscrcpy.Core.psm1") -Force

# Optional GUI shortcut: -Gui forwards to GUI script.
if ($Gui) {
    & (Join-Path $PSScriptRoot "WBscrcpy.Gui.ps1")
    exit $LASTEXITCODE
}

# --- CLI prompts -----------------------------------------------------------

function Read-Choice {
    param([string]$Prompt, [string[]]$ValidChoices)
    $lower = @($ValidChoices | ForEach-Object { $_.ToLowerInvariant() })
    while ($true) {
        $value = (Read-Host $Prompt).Trim().ToLowerInvariant()
        if ($lower -contains $value) { return $value }
        Write-WarnMsg "Invalid. Valid: $($ValidChoices -join ', ')"
    }
}

function Read-IntInRange {
    param(
        [string]$Prompt, [int]$Min, [int]$Max,
        [bool]$AllowEmpty = $false, [int]$DefaultValue = 0
    )
    while ($true) {
        $raw = (Read-Host $Prompt).Trim()
        if ($AllowEmpty -and [string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) { return $parsed }
        Write-WarnMsg "Number $Min-$Max."
    }
}

function Show-PresetList {
    param([hashtable]$Presets)
    if ($Presets.Count -eq 0) { Write-WarnMsg "No presets saved."; return }
    Write-Info "Saved presets:"
    foreach ($n in ($Presets.Keys | Sort-Object)) {
        $p = $Presets[$n]
        Write-Host (" - {0}: mode={1}, display={2}, ip={3}, port={4}" -f $n, $p.Mode, $p.DisplayMode, $p.IP, $p.Port)
    }
}

function Select-DeviceFromList {
    param([object[]]$Devices, [string]$Title)
    if ($Devices.Count -eq 1) {
        Write-Ok "Auto-selected: $($Devices[0].Serial)"
        return $Devices[0].Serial
    }
    Write-Host ""; Write-Info $Title
    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $d = $Devices[$i]
        Write-Host ("{0}. {1} [{2}]" -f ($i + 1), $d.Serial, $d.State)
    }
    $idx = Read-IntInRange -Prompt "Select device number" -Min 1 -Max $Devices.Count
    return $Devices[$idx - 1].Serial
}

# --- Main ------------------------------------------------------------------

try {
    $presets = Import-Presets

    if ($ListPresets) {
        Show-PresetList -Presets $presets
        exit 0
    }

    if ($HealthCheck) {
        $checkIp   = if ([string]::IsNullOrWhiteSpace($IP)) { $DefaultIP } else { $IP }
        $checkPort = if ($Port -gt 0) { $Port } else { $DefaultPort }
        Write-Info "Health check..."
        $results = Invoke-HealthCheck -IPAddress $checkIp -Port $checkPort
        foreach ($r in $results) {
            switch ($r.Status) {
                "Ok"   { Write-Ok      ("[OK]   {0}: {1}" -f $r.Name, $r.Detail) }
                "Warn" { Write-WarnMsg ("[WARN] {0}: {1}" -f $r.Name, $r.Detail) }
                "Fail" { Write-ErrMsg  ("[FAIL] {0}: {1}" -f $r.Name, $r.Detail) }
            }
        }
        exit 0
    }

    Assert-CommandAvailable -Name "adb"
    Assert-CommandAvailable -Name "scrcpy"
    Write-Info "Starting ADB server..."
    Start-AdbServer

    $config = New-LaunchConfig -DefaultIP $DefaultIP -DefaultPort $DefaultPort

    # Layer 1: preset
    if (-not [string]::IsNullOrWhiteSpace($LoadPreset)) {
        if (-not $presets.ContainsKey($LoadPreset)) {
            throw "Preset '$LoadPreset' not found. Use -ListPresets."
        }
        Copy-PresetToConfig -Config $config -Preset $presets[$LoadPreset]
        Write-Ok "Loaded preset '$LoadPreset'"
    }

    # Layer 2: explicit CLI params override preset
    if ($PSBoundParameters.ContainsKey("Mode"))               { $config.Mode = $Mode }
    if ($PSBoundParameters.ContainsKey("DisplayMode"))        { $config.DisplayMode = $DisplayMode }
    if ($PSBoundParameters.ContainsKey("DeviceSerial"))       { $config.DeviceSerial = $DeviceSerial }
    if ($PSBoundParameters.ContainsKey("IP"))                 { $config.IP = $IP }
    if ($PSBoundParameters.ContainsKey("Port"))               { $config.Port = $Port }
    if ($PSBoundParameters.ContainsKey("MaxFps"))             { $config.MaxFps = $MaxFps }
    if ($PSBoundParameters.ContainsKey("Bitrate"))            { $config.Bitrate = $Bitrate }
    if ($PSBoundParameters.ContainsKey("Codec"))              { $config.Codec = $Codec }
    if ($PSBoundParameters.ContainsKey("Density"))            { $config.Density = $Density }
    if ($PSBoundParameters.ContainsKey("ResetDensityOnExit")) { $config.ResetDensityOnExit = [bool]$ResetDensityOnExit }
    if ($PSBoundParameters.ContainsKey("NoWakeLock"))         { $config.NoWakeLock = [bool]$NoWakeLock }

    $interactive = ($config.Mode -eq "Interactive")

    if ($interactive) {
        # Offer preset load (only if none loaded yet)
        if ($presets.Count -gt 0 -and [string]::IsNullOrWhiteSpace($LoadPreset)) {
            $usePreset = Read-Choice -Prompt "Load a preset first? (y/n)" -ValidChoices @("y", "n")
            if ($usePreset -eq "y") {
                Show-PresetList -Presets $presets
                $picked = (Read-Host "Preset name").Trim()
                if ($presets.ContainsKey($picked)) {
                    Copy-PresetToConfig -Config $config -Preset $presets[$picked]
                    Write-Ok "Loaded '$picked'"
                    $LoadPreset = $picked
                } else {
                    Write-WarnMsg "Preset '$picked' not found. Continuing manually."
                }
            }
        }

        # Connection mode: keep preset value if loaded, else ask
        if ([string]::IsNullOrWhiteSpace($LoadPreset) -or $config.Mode -eq "Interactive") {
            Write-Host ""; Write-Info "=== scrcpy Smart Launcher ==="
            Write-Host "1. USB"; Write-Host "2. Network (Wi-Fi/Ethernet)"
            $c = Read-Choice -Prompt "Choose connection type" -ValidChoices @("1", "2")
            $config.Mode = if ($c -eq "1") { "USB" } else { "Network" }
        } else {
            Write-Info "Using preset connection: $($config.Mode)"
        }

        # Display mode: keep preset value if loaded, else ask
        if ([string]::IsNullOrWhiteSpace($LoadPreset)) {
            Write-Host ""; Write-Info "Display modes:"
            Write-Host "1. Normal window"
            Write-Host "2. Fullscreen"
            Write-Host "3. Fullscreen + Screen OFF"
            Write-Host "4. Borderless fullscreen"
            Write-Host "5. High quality (1080p / 8M)"
            Write-Host "6. Custom density + Fullscreen + Screen OFF"
            $config.DisplayMode = Read-Choice -Prompt "Choose display mode" -ValidChoices @("1", "2", "3", "4", "5", "6")
        } else {
            Write-Info "Using preset display mode: $($config.DisplayMode)"
        }

        if ($config.Mode -eq "Network") {
            $ipInput = (Read-Host "Device IP (default: $($config.IP))").Trim()
            if (-not [string]::IsNullOrWhiteSpace($ipInput)) { $config.IP = $ipInput }
            $config.Port = Read-IntInRange -Prompt "Port (default: $($config.Port))" -Min 1 -Max 65535 -AllowEmpty $true -DefaultValue $config.Port
        }

        if (-not $NoInteractiveTuning -and [string]::IsNullOrWhiteSpace($LoadPreset)) {
            $tune = Read-Choice -Prompt "Tune fps/codec/bitrate? (y/n)" -ValidChoices @("y", "n")
            if ($tune -eq "y") {
                $config.MaxFps  = Read-IntInRange -Prompt "Max FPS (15-144, blank skip)" -Min 15 -Max 144 -AllowEmpty $true -DefaultValue $config.MaxFps
                $br = (Read-Host "Bitrate, e.g. 8M (blank skip)").Trim()
                if (-not [string]::IsNullOrWhiteSpace($br)) { $config.Bitrate = $br }
                $cd = (Read-Host "Codec h264/h265/av1 (blank skip)").Trim().ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($cd)) {
                    if (@("h264", "h265", "av1") -contains $cd) { $config.Codec = $cd }
                    else { Write-WarnMsg "Unknown codec '$cd'. Ignored." }
                }
            }
        }

        if ($config.DisplayMode -eq "6" -and ($config.Density -lt 120 -or $config.Density -gt 640)) {
            $config.Density = Read-IntInRange -Prompt "Density (120-640)" -Min 120 -Max 640
            $rd = Read-Choice -Prompt "Reset density on exit? (y/n)" -ValidChoices @("y", "n")
            $config.ResetDensityOnExit = ($rd -eq "y")
        }

        if ([string]::IsNullOrWhiteSpace($SavePreset)) {
            $ws = Read-Choice -Prompt "Save this setup as preset? (y/n)" -ValidChoices @("y", "n")
            if ($ws -eq "y") { $SavePreset = (Read-Host "Preset name").Trim() }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SavePreset)) {
        Save-PresetFromConfig -Presets $presets -Name $SavePreset -Config $config
        Write-Ok "Preset '$SavePreset' saved."
    }

    if ($NoLaunch) {
        Write-Info "NoLaunch set. Exiting without starting scrcpy."
        exit 0
    }

    # Resolve USB interactively if multiple devices
    if ($config.Mode -eq "USB" -and [string]::IsNullOrWhiteSpace($config.DeviceSerial)) {
        $usb = Resolve-UsbDevice -RequestedSerial $null
        if ($usb -is [string]) {
            $config.DeviceSerial = $usb
        } else {
            $config.DeviceSerial = Select-DeviceFromList -Devices $usb -Title "USB devices detected:"
        }
    }

    Write-Host ""
    Write-Ok "Launching scrcpy..."
    $exitCode = Invoke-Scrcpy -Config $config -Logger { param($m) Write-Host $m -ForegroundColor DarkGray }
    Write-Ok "scrcpy session ended (exit $exitCode)."
}
catch {
    Write-ErrMsg $_.Exception.Message
    exit 1
}
