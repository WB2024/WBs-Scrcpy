# Build-Exe.ps1 — package WBscrcpy as standalone .exe via ps2exe.
#
# Output: dist/WBscrcpy.exe (GUI by default) plus copied module + presets template.
# Usage:
#   .\Build-Exe.ps1                 # GUI exe (default, no console)
#   .\Build-Exe.ps1 -Cli            # CLI exe (console)
#   .\Build-Exe.ps1 -Both           # both
#   .\Build-Exe.ps1 -OutDir dist    # custom output dir

[CmdletBinding()]
param(
    [switch]$Cli,
    [switch]$Both,
    [string]$OutDir,
    [string]$IconPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $ScriptRoot "dist"
}

function Ensure-Ps2Exe {
    if (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue) { return }
    if (Get-Command ps2exe -ErrorAction SilentlyContinue) { return }

    Write-Host "ps2exe module not found. Installing for current user..." -ForegroundColor Cyan
    try {
        Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        throw "Could not install ps2exe automatically. Run: Install-Module ps2exe -Scope CurrentUser. Original error: $($_.Exception.Message)"
    }

    # Install-Module does not update $env:PSModulePath in the current session.
    # Locate the installed manifest explicitly and import by full path.
    $ps2exeManifest = $null
    foreach ($root in @(
        (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\Modules"),
        (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "PowerShell\Modules"),
        (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules"),
        (Join-Path $env:ProgramFiles "PowerShell\Modules")
    )) {
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -Recurse -Filter "ps2exe.psd1" -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { $ps2exeManifest = $found; break }
        }
    }

    if (-not $ps2exeManifest) {
        throw "ps2exe installed but manifest not found. Add its Modules folder to PSModulePath and re-run."
    }
    Import-Module $ps2exeManifest.FullName -Force
}

function Compile-Script {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$NoConsole
    )

    $useNoConsole = [bool]$NoConsole.IsPresent

    Write-Host "Compiling $Source -> $OutputPath" -ForegroundColor Cyan

    if ($IconPath -and (Test-Path $IconPath)) {
        Invoke-PS2EXE -inputFile $Source -outputFile $OutputPath -noConsole:$useNoConsole -iconFile $IconPath -verbose
        return
    }

    Invoke-PS2EXE -inputFile $Source -outputFile $OutputPath -noConsole:$useNoConsole -verbose
}

try {
    Ensure-Ps2Exe

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

    $corePath = Join-Path $ScriptRoot "WBscrcpy.Core.psm1"
    $cliPath  = Join-Path $ScriptRoot "WBscrcpy.ps1"
    $guiPath  = Join-Path $ScriptRoot "WBscrcpy.Gui.ps1"

    foreach ($f in @($corePath, $cliPath, $guiPath)) {
        if (-not (Test-Path $f)) { throw "Required source not found: $f" }
    }

    # Module must sit next to the .exe at runtime
    Copy-Item -Path $corePath -Destination $OutDir -Force

    $buildGui = -not $Cli -or $Both
    $buildCli = $Cli -or $Both

    if ($buildGui) {
        Compile-Script -Source $guiPath -OutputPath (Join-Path $OutDir "WBscrcpy.exe") -NoConsole:$true
    }
    if ($buildCli) {
        Compile-Script -Source $cliPath -OutputPath (Join-Path $OutDir "WBscrcpy-cli.exe") -NoConsole:$false
    }

    Write-Host ""
    Write-Host "Done. Output:" -ForegroundColor Green
    Get-ChildItem $OutDir | ForEach-Object { Write-Host (" - {0}" -f $_.FullName) }
    Write-Host ""
    Write-Host "Run the .exe(s) directly. WBscrcpy.Core.psm1 must remain alongside the .exe." -ForegroundColor Yellow
}
catch {
    Write-Host "Build failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkRed
    }
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    exit 1
}
