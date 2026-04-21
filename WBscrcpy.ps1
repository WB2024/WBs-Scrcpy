# scrcpy Smart Launcher Script (Enhanced + Hardened + Presets)

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
    [switch]$ListPresets,

    [switch]$HealthCheck,
    [switch]$NoWakeLock,
    [switch]$NoInteractiveTuning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PresetPath = Join-Path -Path $PSScriptRoot -ChildPath "WBscrcpy.presets.json"

function Write-Info([string]$Message) {
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host $Message -ForegroundColor Green
}

function Write-WarnMsg([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
}

function Write-ErrMsg([string]$Message) {
    Write-Host $Message -ForegroundColor Red
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found in PATH."
    }
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$ValidChoices
    )

    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if ($ValidChoices -contains $value) {
            return $value
        }

        Write-WarnMsg "Invalid choice. Valid values: $($ValidChoices -join ', ')"
    }
}

function Read-IntInRange {
    param(
        [string]$Prompt,
        [int]$Min,
        [int]$Max,
        [bool]$AllowEmpty = $false,
        [int]$DefaultValue = 0
    )

    while ($true) {
        $raw = (Read-Host $Prompt).Trim()

        if ($AllowEmpty -and [string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultValue
        }

        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) {
            return $parsed
        }

        Write-WarnMsg "Enter a number from $Min to $Max."
    }
}

function Test-IPv4([string]$IPAddress) {
    $address = $null
    $ok = [System.Net.IPAddress]::TryParse($IPAddress, [ref]$address)
    return $ok -and $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Start-ADBServer {
    Write-Info "Starting ADB server..."
    adb start-server | Out-Null
}

function Get-ADBDeviceObjects {
    $lines = adb devices | Select-Object -Skip 1
    $items = @()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $parts = $trimmed -split "\s+"
        if ($parts.Count -lt 2) {
            continue
        }

        $items += [PSCustomObject]@{
            Serial = $parts[0]
            State  = $parts[1]
            IsTcp  = ($parts[0] -match ":\d+$")
        }
    }

    return $items
}

function New-LaunchConfig {
    return [PSCustomObject]@{
        Mode              = "Interactive"
        DisplayMode       = "1"
        DeviceSerial      = $null
        IP                = $DefaultIP
        Port              = $DefaultPort
        MaxFps            = 0
        Bitrate           = $null
        Codec             = $null
        Density           = 0
        ResetDensityOnExit = $false
        NoWakeLock        = $false
    }
}

function Import-Presets {
    if (-not (Test-Path $script:PresetPath)) {
        return @{}
    }

    $raw = Get-Content -Path $script:PresetPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $obj = $raw | ConvertFrom-Json
    $map = @{}
    foreach ($prop in $obj.PSObject.Properties) {
        $map[$prop.Name] = $prop.Value
    }
    return $map
}

function Export-Presets([hashtable]$Presets) {
    $json = $Presets | ConvertTo-Json -Depth 5
    Set-Content -Path $script:PresetPath -Value $json -Encoding UTF8
}

function Show-PresetList([hashtable]$Presets) {
    if ($Presets.Count -eq 0) {
        Write-WarnMsg "No presets saved yet."
        return
    }

    Write-Info "Saved presets:"
    foreach ($name in ($Presets.Keys | Sort-Object)) {
        $p = $Presets[$name]
        Write-Host (" - {0}: mode={1}, display={2}, ip={3}, port={4}" -f $name, $p.Mode, $p.DisplayMode, $p.IP, $p.Port)
    }
}

function Apply-PresetToConfig {
    param(
        [PSCustomObject]$Config,
        [object]$Preset
    )

    foreach ($prop in $Config.PSObject.Properties.Name) {
        if ($Preset.PSObject.Properties.Name -contains $prop -and $null -ne $Preset.$prop) {
            $Config.$prop = $Preset.$prop
        }
    }
}

function Save-ConfigAsPreset {
    param(
        [hashtable]$Presets,
        [string]$Name,
        [PSCustomObject]$Config
    )

    $Presets[$Name] = [PSCustomObject]@{
        Mode               = $Config.Mode
        DisplayMode        = $Config.DisplayMode
        DeviceSerial       = $Config.DeviceSerial
        IP                 = $Config.IP
        Port               = $Config.Port
        MaxFps             = $Config.MaxFps
        Bitrate            = $Config.Bitrate
        Codec              = $Config.Codec
        Density            = $Config.Density
        ResetDensityOnExit = [bool]$Config.ResetDensityOnExit
        NoWakeLock         = [bool]$Config.NoWakeLock
    }

    Export-Presets -Presets $Presets
    Write-Ok "Saved preset '$Name' to $script:PresetPath"
}

function Select-DeviceFromList {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Devices,

        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    if ($Devices.Count -eq 1) {
        Write-Ok "Auto-selected: $($Devices[0].Serial)"
        return $Devices[0].Serial
    }

    Write-Host ""
    Write-Info $Title
    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $d = $Devices[$i]
        Write-Host ("{0}. {1} [{2}]" -f ($i + 1), $d.Serial, $d.State)
    }

    $index = Read-IntInRange -Prompt "Select device number" -Min 1 -Max $Devices.Count
    return $Devices[$index - 1].Serial
}

function Use-USB {
    param([string]$RequestedSerial)

    $all = Get-ADBDeviceObjects
    $bad = $all | Where-Object { $_.State -ne "device" }
    if ($bad.Count -gt 0) {
        Write-WarnMsg "Some devices are not ready:"
        foreach ($item in $bad) {
            Write-Host " - $($item.Serial) [$($item.State)]"
        }
    }

    $usbDevices = $all | Where-Object { $_.State -eq "device" -and -not $_.IsTcp }
    if ($usbDevices.Count -eq 0) {
        throw "No USB devices detected in 'device' state."
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedSerial)) {
        $match = $usbDevices | Where-Object { $_.Serial -eq $RequestedSerial }
        if ($match.Count -eq 0) {
            throw "Requested USB serial '$RequestedSerial' not found in ready USB devices."
        }
        return $RequestedSerial
    }

    return Select-DeviceFromList -Devices $usbDevices -Title "USB devices detected:"
}

function Use-Network {
    param(
        [string]$IPAddress,
        [int]$DevicePort,
        [string]$RequestedSerial
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSerial)) {
        $all = Get-ADBDeviceObjects
        $match = $all | Where-Object { $_.Serial -eq $RequestedSerial -and $_.State -eq "device" }
        if ($match.Count -eq 0) {
            throw "Requested network serial '$RequestedSerial' is not in ready device state."
        }
        return $RequestedSerial
    }

    if (-not (Test-IPv4 $IPAddress)) {
        throw "Invalid IPv4 address: $IPAddress"
    }
    if ($DevicePort -lt 1 -or $DevicePort -gt 65535) {
        throw "Invalid port: $DevicePort"
    }

    $target = "${IPAddress}:$DevicePort"

    Write-Info "Connecting to $target ..."
    $connectResult = adb connect $target
    if ($connectResult -notmatch "connected to|already connected to") {
        throw "ADB connect failed for $target. Output: $connectResult"
    }

    Start-Sleep -Milliseconds 700

    $all = Get-ADBDeviceObjects
    $match = $all | Where-Object { $_.Serial -eq $target -and $_.State -eq "device" }
    if ($match.Count -eq 0) {
        throw "Connected to $target but device is not ready. Check phone prompt and USB debugging authorization."
    }

    return $target
}

function Cleanup-OtherTcpDevices([string]$SelectedSerial) {
    $all = Get-ADBDeviceObjects
    foreach ($d in $all) {
        if ($d.IsTcp -and $d.Serial -ne $SelectedSerial) {
            adb disconnect $d.Serial | Out-Null
        }
    }
}

function Show-ConnectionMenu {
    Write-Host ""
    Write-Info "=== scrcpy Smart Launcher ==="
    Write-Host "1. USB"
    Write-Host "2. Network (Wi-Fi/Ethernet)"
    $choice = Read-Choice -Prompt "Choose connection type" -ValidChoices @("1", "2")
    if ($choice -eq "1") { return "USB" }
    return "Network"
}

function Show-DisplayMenu {
    Write-Host ""
    Write-Info "Display modes:"
    Write-Host "1. Normal window"
    Write-Host "2. Fullscreen"
    Write-Host "3. Fullscreen + Screen OFF"
    Write-Host "4. Borderless fullscreen"
    Write-Host "5. High quality (1080p / 8M)"
    Write-Host "6. Custom density + Fullscreen + Screen OFF"
    return Read-Choice -Prompt "Choose display mode" -ValidChoices @("1", "2", "3", "4", "5", "6")
}

function Get-ExtraPerfConfig {
    $enable = Read-Choice -Prompt "Tune frame rate / codec / bitrate? (y/n)" -ValidChoices @("y", "n")
    if ($enable -eq "n") {
        return [PSCustomObject]@{ MaxFps = 0; Bitrate = $null; Codec = $null }
    }

    $fps = Read-IntInRange -Prompt "Max FPS (15-144, blank = skip)" -Min 15 -Max 144 -AllowEmpty $true -DefaultValue 0
    $bitrate = (Read-Host "Bitrate, e.g. 8M (blank = skip)").Trim()
    $codec = (Read-Host "Codec h264/h265/av1 (blank = skip)").Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($codec) -and @("h264", "h265", "av1") -notcontains $codec) {
        Write-WarnMsg "Unknown codec '$codec'. Ignoring."
        $codec = $null
    }

    return [PSCustomObject]@{ MaxFps = $fps; Bitrate = $bitrate; Codec = $codec }
}

function Enable-StayAwake([string]$Serial) {
    adb -s $Serial shell svc power stayon true | Out-Null
}

function Disable-StayAwake([string]$Serial) {
    adb -s $Serial shell svc power stayon false | Out-Null
}

function Set-CustomDensity([string]$Serial, [int]$Value) {
    adb -s $Serial shell wm density $Value | Out-Null
}

function Reset-Density([string]$Serial) {
    adb -s $Serial shell wm density reset | Out-Null
}

function Build-ScrcpyArgs {
    param(
        [string]$Serial,
        [PSCustomObject]$Config
    )

    $args = @("-s", $Serial)

    switch ($Config.DisplayMode) {
        "2" { $args += "--fullscreen" }
        "3" { $args += @("--fullscreen", "--turn-screen-off") }
        "4" { $args += @("--fullscreen", "--window-borderless") }
        "5" { $args += @("--fullscreen", "--max-size", "1920", "--video-bit-rate", "8M") }
        "6" { $args += @("--fullscreen", "--turn-screen-off") }
    }

    if ($Config.MaxFps -gt 0) {
        $args += @("--max-fps", "$($Config.MaxFps)")
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.Bitrate)) {
        $args += @("--video-bit-rate", $Config.Bitrate)
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.Codec)) {
        $args += @("--video-codec", $Config.Codec)
    }

    return $args
}

function Invoke-HealthCheck {
    param(
        [string]$IPAddress,
        [int]$DevicePort
    )

    Write-Info "Running health checks..."

    $adbFound = [bool](Get-Command adb -ErrorAction SilentlyContinue)
    $scrcpyFound = [bool](Get-Command scrcpy -ErrorAction SilentlyContinue)

    if ($adbFound) { Write-Ok "adb found in PATH" } else { Write-ErrMsg "adb not found in PATH" }
    if ($scrcpyFound) { Write-Ok "scrcpy found in PATH" } else { Write-ErrMsg "scrcpy not found in PATH" }

    if (-not $adbFound) {
        return
    }

    try {
        adb start-server | Out-Null
        Write-Ok "adb server is running"
    }
    catch {
        Write-ErrMsg "Failed to start adb server"
        return
    }

    $devices = Get-ADBDeviceObjects
    if ($devices.Count -eq 0) {
        Write-WarnMsg "No adb devices currently detected"
    }
    else {
        Write-Info "Detected adb devices:"
        foreach ($d in $devices) {
            Write-Host (" - {0} [{1}]" -f $d.Serial, $d.State)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($IPAddress) -and (Test-IPv4 $IPAddress)) {
        $pingOk = Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($pingOk) {
            Write-Ok "Ping to $IPAddress succeeded"
        }
        else {
            Write-WarnMsg "Ping to $IPAddress failed (device might still be reachable for adb)."
        }

        if ($DevicePort -ge 1 -and $DevicePort -le 65535) {
            $tnc = Test-NetConnection -ComputerName $IPAddress -Port $DevicePort -WarningAction SilentlyContinue
            if ($tnc.TcpTestSucceeded) {
                Write-Ok "TCP $IPAddress`:$DevicePort is reachable"
            }
            else {
                Write-WarnMsg "TCP $IPAddress`:$DevicePort is not reachable"
            }
        }
    }
}

try {
    $presets = Import-Presets

    if ($ListPresets) {
        Show-PresetList -Presets $presets
        exit 0
    }

    if ($HealthCheck) {
        $checkIp = if ([string]::IsNullOrWhiteSpace($IP)) { $DefaultIP } else { $IP }
        $checkPort = if ($Port -gt 0) { $Port } else { $DefaultPort }
        Invoke-HealthCheck -IPAddress $checkIp -DevicePort $checkPort
        exit 0
    }

    Require-Command -Name "adb"
    Require-Command -Name "scrcpy"
    Start-ADBServer

    $config = New-LaunchConfig

    if (-not [string]::IsNullOrWhiteSpace($LoadPreset)) {
        if (-not $presets.ContainsKey($LoadPreset)) {
            throw "Preset '$LoadPreset' was not found. Use -ListPresets to inspect saved presets."
        }
        Apply-PresetToConfig -Config $config -Preset $presets[$LoadPreset]
        Write-Ok "Loaded preset '$LoadPreset'"
    }

    if ($PSBoundParameters.ContainsKey("Mode")) { $config.Mode = $Mode }
    if ($PSBoundParameters.ContainsKey("DisplayMode")) { $config.DisplayMode = $DisplayMode }
    if ($PSBoundParameters.ContainsKey("DeviceSerial")) { $config.DeviceSerial = $DeviceSerial }
    if ($PSBoundParameters.ContainsKey("IP")) { $config.IP = $IP }
    if ($PSBoundParameters.ContainsKey("Port")) { $config.Port = $Port }
    if ($PSBoundParameters.ContainsKey("MaxFps")) { $config.MaxFps = $MaxFps }
    if ($PSBoundParameters.ContainsKey("Bitrate")) { $config.Bitrate = $Bitrate }
    if ($PSBoundParameters.ContainsKey("Codec")) { $config.Codec = $Codec }
    if ($PSBoundParameters.ContainsKey("Density")) { $config.Density = $Density }
    if ($PSBoundParameters.ContainsKey("ResetDensityOnExit")) { $config.ResetDensityOnExit = [bool]$ResetDensityOnExit }
    if ($PSBoundParameters.ContainsKey("NoWakeLock")) { $config.NoWakeLock = [bool]$NoWakeLock }

    $interactiveFlow = ($config.Mode -eq "Interactive")

    if ($interactiveFlow) {
        if ($presets.Count -gt 0 -and [string]::IsNullOrWhiteSpace($LoadPreset)) {
            $usePreset = Read-Choice -Prompt "Load a preset first? (y/n)" -ValidChoices @("y", "n")
            if ($usePreset -eq "y") {
                Show-PresetList -Presets $presets
                $picked = Read-Host "Preset name"
                if ($presets.ContainsKey($picked)) {
                    Apply-PresetToConfig -Config $config -Preset $presets[$picked]
                    Write-Ok "Loaded preset '$picked'"
                }
                else {
                    Write-WarnMsg "Preset '$picked' not found. Continuing with manual choices."
                }
            }
        }

        $config.Mode = Show-ConnectionMenu
        $config.DisplayMode = Show-DisplayMenu

        if ($config.Mode -eq "Network") {
            $ipInput = (Read-Host "Enter device IP (default: $($config.IP))").Trim()
            if (-not [string]::IsNullOrWhiteSpace($ipInput)) {
                $config.IP = $ipInput
            }
            $config.Port = Read-IntInRange -Prompt "Enter port (default: $($config.Port))" -Min 1 -Max 65535 -AllowEmpty $true -DefaultValue $config.Port
        }

        if (-not $NoInteractiveTuning) {
            $perf = Get-ExtraPerfConfig
            $config.MaxFps = $perf.MaxFps
            $config.Bitrate = $perf.Bitrate
            $config.Codec = $perf.Codec
        }

        if ($config.DisplayMode -eq "6") {
            $config.Density = Read-IntInRange -Prompt "Enter density (120-640)" -Min 120 -Max 640
            $resetDensity = Read-Choice -Prompt "Reset density to default when scrcpy exits? (y/n)" -ValidChoices @("y", "n")
            $config.ResetDensityOnExit = ($resetDensity -eq "y")
        }

        if ([string]::IsNullOrWhiteSpace($SavePreset)) {
            $wantSave = Read-Choice -Prompt "Save this setup as a preset? (y/n)" -ValidChoices @("y", "n")
            if ($wantSave -eq "y") {
                $SavePreset = (Read-Host "Preset name").Trim()
            }
        }
    }
    else {
        if ($config.Mode -eq "Network") {
            if ([string]::IsNullOrWhiteSpace($config.IP)) {
                throw "Network mode requires IP (use -IP or a preset with IP)."
            }
            if ($config.Port -lt 1 -or $config.Port -gt 65535) {
                throw "Network mode requires a valid -Port between 1 and 65535."
            }
        }
        if ([string]::IsNullOrWhiteSpace($config.DisplayMode)) {
            $config.DisplayMode = "1"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SavePreset)) {
        Save-ConfigAsPreset -Presets $presets -Name $SavePreset -Config $config
    }

    $device = if ($config.Mode -eq "USB") {
        Use-USB -RequestedSerial $config.DeviceSerial
    }
    else {
        Use-Network -IPAddress $config.IP -DevicePort $config.Port -RequestedSerial $config.DeviceSerial
    }

    Cleanup-OtherTcpDevices -SelectedSerial $device

    if ($config.DisplayMode -eq "6") {
        if ($config.Density -lt 120 -or $config.Density -gt 640) {
            throw "Display mode 6 requires density value 120-640 (set -Density or choose interactively)."
        }
        Set-CustomDensity -Serial $device -Value $config.Density
    }

    $scrcpyArgs = Build-ScrcpyArgs -Serial $device -Config $config

    Write-Host ""
    Write-Ok "Launching scrcpy for device: $device"
    Write-Host "Arguments: $($scrcpyArgs -join ' ')" -ForegroundColor DarkGray

    if (-not $config.NoWakeLock) {
        Enable-StayAwake -Serial $device
    }

    $proc = Start-Process -FilePath "scrcpy" -ArgumentList $scrcpyArgs -PassThru
    $proc.WaitForExit()

    if (-not $config.NoWakeLock) {
        Disable-StayAwake -Serial $device
    }

    if ($config.DisplayMode -eq "6" -and $config.ResetDensityOnExit) {
        Reset-Density -Serial $device
        Write-Ok "Density reset to system default."
    }

    Write-Ok "scrcpy session ended."
}
catch {
    Write-ErrMsg $_.Exception.Message
    exit 1
}
