# WBscrcpy.Core.psm1 — shared logic for CLI and GUI front-ends.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----- Console helpers (CLI uses these; GUI ignores) -----------------------

function Write-Info ([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Ok   ([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnMsg ([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-ErrMsg  ([string]$Message) { Write-Host $Message -ForegroundColor Red }

# ----- Validation ----------------------------------------------------------

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-CommandAvailable -Name $Name)) {
        throw "Required command '$Name' not found in PATH."
    }
}

function Test-IPv4 {
    param([string]$IPAddress)
    if ([string]::IsNullOrWhiteSpace($IPAddress)) { return $false }
    $address = $null
    $ok = [System.Net.IPAddress]::TryParse($IPAddress, [ref]$address)
    return $ok -and $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-PortValid {
    param([int]$Port)
    return ($Port -ge 1 -and $Port -le 65535)
}

# ----- ADB plumbing --------------------------------------------------------

function Start-AdbServer {
    adb start-server | Out-Null
}

function Get-AdbDevice {
    # Always returns an array (possibly empty). Each item: Serial, State, IsTcp.
    $raw = adb devices 2>$null
    if (-not $raw) { return @() }
    $lines = @($raw) | Select-Object -Skip 1
    $items = @()
    foreach ($line in $lines) {
        $trimmed = "$line".Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $parts = $trimmed -split "\s+"
        if ($parts.Count -lt 2) { continue }
        $items += [PSCustomObject]@{
            Serial = $parts[0]
            State  = $parts[1]
            IsTcp  = ($parts[0] -match ":\d+$")
        }
    }
    return ,$items
}

function Connect-AdbNetworkDevice {
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$RetryCount = 3,
        [int]$RetryDelayMs = 700
    )

    if (-not (Test-IPv4 $IPAddress))   { throw "Invalid IPv4 address: $IPAddress" }
    if (-not (Test-PortValid $Port))   { throw "Invalid port: $Port" }

    $target = "${IPAddress}:$Port"
    $connectResult = adb connect $target 2>&1
    if ("$connectResult" -notmatch "connected to|already connected to") {
        throw "ADB connect failed for $target. Output: $connectResult"
    }

    for ($i = 0; $i -lt $RetryCount; $i++) {
        Start-Sleep -Milliseconds $RetryDelayMs
        $all = Get-AdbDevice
        $match = @($all | Where-Object { $_.Serial -eq $target -and $_.State -eq "device" })
        if ($match.Count -gt 0) { return $target }
    }

    throw "Connected to $target but device not 'device' state. Check phone authorisation prompt."
}

function Disconnect-StaleTcpDevices {
    param(
        [Parameter(Mandatory)][string]$KeepSerial,
        [scriptblock]$Logger
    )
    $all = Get-AdbDevice
    foreach ($d in $all) {
        if ($d.IsTcp -and $d.Serial -ne $KeepSerial) {
            adb disconnect $d.Serial | Out-Null
            if ($Logger) { & $Logger "Disconnected stale TCP device: $($d.Serial)" }
        }
    }
}

function Resolve-UsbDevice {
    param([string]$RequestedSerial)

    $all = Get-AdbDevice
    $usb = @($all | Where-Object { $_.State -eq "device" -and -not $_.IsTcp })
    if ($usb.Count -eq 0) {
        throw "No USB devices in 'device' state. Check cable and authorisation."
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedSerial)) {
        $match = @($usb | Where-Object { $_.Serial -eq $RequestedSerial })
        if ($match.Count -eq 0) {
            throw "Requested USB serial '$RequestedSerial' not found among ready devices."
        }
        return $RequestedSerial
    }
    return $usb
}

function Resolve-NetworkDevice {
    param(
        [string]$IPAddress,
        [int]$Port,
        [string]$RequestedSerial
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSerial)) {
        $all = Get-AdbDevice
        $match = @($all | Where-Object { $_.Serial -eq $RequestedSerial -and $_.State -eq "device" })
        if ($match.Count -eq 0) {
            # Try connect if serial looks like host:port
            if ($RequestedSerial -match '^([\d\.]+):(\d+)$') {
                return (Connect-AdbNetworkDevice -IPAddress $matches[1] -Port [int]$matches[2])
            }
            throw "Requested network serial '$RequestedSerial' is not ready."
        }
        return $RequestedSerial
    }
    return (Connect-AdbNetworkDevice -IPAddress $IPAddress -Port $Port)
}

# ----- Device control ------------------------------------------------------

function Enable-StayAwake  { param([string]$Serial); adb -s $Serial shell svc power stayon true  | Out-Null }
function Disable-StayAwake { param([string]$Serial); adb -s $Serial shell svc power stayon false | Out-Null }
function Set-DeviceDensity { param([string]$Serial, [int]$Value); adb -s $Serial shell wm density $Value | Out-Null }
function Reset-DeviceDensity { param([string]$Serial); adb -s $Serial shell wm density reset | Out-Null }

# ----- Config / presets ----------------------------------------------------

function New-LaunchConfig {
    param(
        [string]$DefaultIP = "192.168.1.220",
        [int]$DefaultPort = 5555
    )
    return [PSCustomObject]@{
        Mode               = "Interactive"
        DisplayMode        = "1"
        DeviceSerial       = $null
        IP                 = $DefaultIP
        Port               = $DefaultPort
        MaxFps             = 0
        Bitrate            = $null
        Codec              = $null
        Density            = 0
        ResetDensityOnExit = $false
        NoWakeLock         = $false
    }
}

function Get-DefaultPresetPath {
    if ($PSScriptRoot) {
        return (Join-Path -Path $PSScriptRoot -ChildPath "WBscrcpy.presets.json")
    }
    return (Join-Path -Path (Get-Location) -ChildPath "WBscrcpy.presets.json")
}

function Import-Presets {
    param([string]$Path = (Get-DefaultPresetPath))
    if (-not (Test-Path $Path)) { return @{} }
    $raw = Get-Content -Path $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    $obj = $raw | ConvertFrom-Json
    $map = @{}
    foreach ($prop in $obj.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    return $map
}

function Export-Presets {
    param(
        [Parameter(Mandatory)][hashtable]$Presets,
        [string]$Path = (Get-DefaultPresetPath)
    )
    $obj = [PSCustomObject]@{}
    foreach ($k in $Presets.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Presets[$k] }
    $json = $obj | ConvertTo-Json -Depth 5
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Copy-PresetToConfig {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][object]$Preset
    )
    foreach ($prop in $Config.PSObject.Properties.Name) {
        if ($Preset.PSObject.Properties.Name -contains $prop -and $null -ne $Preset.$prop) {
            $Config.$prop = $Preset.$prop
        }
    }
}

function Save-PresetFromConfig {
    param(
        [Parameter(Mandatory)][hashtable]$Presets,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [string]$Path = (Get-DefaultPresetPath)
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
    Export-Presets -Presets $Presets -Path $Path
}

function Remove-Preset {
    param(
        [Parameter(Mandatory)][hashtable]$Presets,
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = (Get-DefaultPresetPath)
    )
    if ($Presets.ContainsKey($Name)) {
        $Presets.Remove($Name)
        Export-Presets -Presets $Presets -Path $Path
    }
}

# ----- scrcpy argv builder -------------------------------------------------

function Build-ScrcpyArgs {
    param(
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $argv = [System.Collections.Generic.List[string]]::new()
    $argv.Add("-s"); $argv.Add($Serial)

    $hasMode5Bitrate = $false
    switch ($Config.DisplayMode) {
        "2" { $argv.Add("--fullscreen") }
        "3" { $argv.Add("--fullscreen"); $argv.Add("--turn-screen-off") }
        "4" { $argv.Add("--fullscreen"); $argv.Add("--window-borderless") }
        "5" {
            $argv.Add("--fullscreen")
            $argv.Add("--max-size"); $argv.Add("1920")
            # Honour explicit user bitrate over mode-5 default
            if ([string]::IsNullOrWhiteSpace($Config.Bitrate)) {
                $argv.Add("--video-bit-rate"); $argv.Add("8M")
                $hasMode5Bitrate = $true
            }
        }
        "6" { $argv.Add("--fullscreen"); $argv.Add("--turn-screen-off") }
    }

    if ($Config.MaxFps -gt 0) {
        $argv.Add("--max-fps"); $argv.Add("$($Config.MaxFps)")
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.Bitrate) -and -not $hasMode5Bitrate) {
        $argv.Add("--video-bit-rate"); $argv.Add($Config.Bitrate)
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.Codec)) {
        $argv.Add("--video-codec"); $argv.Add($Config.Codec)
    }

    return ,$argv.ToArray()
}

# ----- Launch orchestrator -------------------------------------------------

function Invoke-Scrcpy {
    <#
        Resolves device, applies density/wake-lock, runs scrcpy, cleans up.
        $Logger optional scriptblock for status messages.
        Returns exit code.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [scriptblock]$Logger,
        [switch]$NoWait
    )

    function _log($m) { if ($Logger) { & $Logger $m } }

    Assert-CommandAvailable -Name "adb"
    Assert-CommandAvailable -Name "scrcpy"
    Start-AdbServer

    if ($Config.Mode -eq "Network") {
        if (-not (Test-IPv4 $Config.IP))    { throw "Network mode requires valid IP." }
        if (-not (Test-PortValid $Config.Port)) { throw "Network mode requires valid port (1-65535)." }
    }

    $device = if ($Config.Mode -eq "USB") {
        $r = Resolve-UsbDevice -RequestedSerial $Config.DeviceSerial
        if ($r -is [string]) { $r } else { throw "Multiple USB devices; specify -DeviceSerial or use interactive/GUI." }
    } else {
        Resolve-NetworkDevice -IPAddress $Config.IP -Port $Config.Port -RequestedSerial $Config.DeviceSerial
    }
    _log "Resolved device: $device"

    Disconnect-StaleTcpDevices -KeepSerial $device -Logger $Logger

    if ($Config.DisplayMode -eq "6") {
        if ($Config.Density -lt 120 -or $Config.Density -gt 640) {
            throw "Display mode 6 requires Density 120-640."
        }
        Set-DeviceDensity -Serial $device -Value $Config.Density
        _log "Density set to $($Config.Density)"
    }

    $argv = Build-ScrcpyArgs -Serial $device -Config $Config
    _log "scrcpy $($argv -join ' ')"

    $wakeApplied = $false
    try {
        if (-not $Config.NoWakeLock) {
            Enable-StayAwake -Serial $device
            $wakeApplied = $true
        }

        $proc = Start-Process -FilePath "scrcpy" -ArgumentList $argv -PassThru
        if ($NoWait) { return $proc }

        $proc.WaitForExit()
        return $proc.ExitCode
    }
    finally {
        if ($wakeApplied) {
            try { Disable-StayAwake -Serial $device } catch { _log "WARN: failed to disable stay-awake: $_" }
        }
        if ($Config.DisplayMode -eq "6" -and $Config.ResetDensityOnExit) {
            try { Reset-DeviceDensity -Serial $device; _log "Density reset." } catch { _log "WARN: density reset failed: $_" }
        }
    }
}

# ----- Health check --------------------------------------------------------

function Invoke-HealthCheck {
    <#
        Returns ordered list of [PSCustomObject]{ Name; Status (Ok/Warn/Fail); Detail }.
    #>
    param(
        [string]$IPAddress,
        [int]$Port
    )

    $results = [System.Collections.Generic.List[object]]::new()
    function _add($n, $s, $d) { $results.Add([PSCustomObject]@{ Name = $n; Status = $s; Detail = $d }) }

    $adbOk = Test-CommandAvailable adb
    _add "adb in PATH"     ($(if ($adbOk) {'Ok'} else {'Fail'}))    ($(if ($adbOk) {'found'} else {'missing'}))

    $scrOk = Test-CommandAvailable scrcpy
    _add "scrcpy in PATH"  ($(if ($scrOk) {'Ok'} else {'Fail'}))    ($(if ($scrOk) {'found'} else {'missing'}))

    if ($adbOk) {
        try { adb start-server | Out-Null; _add "adb server" "Ok" "running" }
        catch { _add "adb server" "Fail" $_.Exception.Message }

        $devs = Get-AdbDevice
        if ($devs.Count -eq 0) {
            _add "adb devices" "Warn" "none detected"
        } else {
            _add "adb devices" "Ok" (($devs | ForEach-Object { "$($_.Serial) [$($_.State)]" }) -join "; ")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($IPAddress) -and (Test-IPv4 $IPAddress)) {
        $pingOk = Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
        _add "Ping $IPAddress" ($(if ($pingOk) {'Ok'} else {'Warn'})) ($(if ($pingOk) {'reply'} else {'no reply'}))

        if (Test-PortValid $Port) {
            try {
                $tnc = Test-NetConnection -ComputerName $IPAddress -Port $Port -WarningAction SilentlyContinue
                _add "TCP ${IPAddress}:$Port" ($(if ($tnc.TcpTestSucceeded) {'Ok'} else {'Warn'})) ($(if ($tnc.TcpTestSucceeded) {'reachable'} else {'unreachable'}))
            } catch {
                _add "TCP ${IPAddress}:$Port" "Warn" $_.Exception.Message
            }
        }
    }

    return ,$results.ToArray()
}

Export-ModuleMember -Function `
    Write-Info, Write-Ok, Write-WarnMsg, Write-ErrMsg, `
    Test-CommandAvailable, Assert-CommandAvailable, Test-IPv4, Test-PortValid, `
    Start-AdbServer, Get-AdbDevice, Connect-AdbNetworkDevice, Disconnect-StaleTcpDevices, `
    Resolve-UsbDevice, Resolve-NetworkDevice, `
    Enable-StayAwake, Disable-StayAwake, Set-DeviceDensity, Reset-DeviceDensity, `
    New-LaunchConfig, Get-DefaultPresetPath, Import-Presets, Export-Presets, `
    Copy-PresetToConfig, Save-PresetFromConfig, Remove-Preset, `
    Build-ScrcpyArgs, Invoke-Scrcpy, Invoke-HealthCheck
