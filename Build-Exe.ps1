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
    [string]$OutDir = (Join-Path $PSScriptRoot "dist"),
    [string]$IconPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Ps2Exe {
    if (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue) { return }
    if (Get-Command ps2exe -ErrorAction SilentlyContinue) { return }

    Write-Host "ps2exe module not found. Installing for current user..." -ForegroundColor Cyan
    try {
        Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        throw "Could not install ps2exe automatically. Run: Install-Module ps2exe -Scope CurrentUser. Original error: $($_.Exception.Message)"
    }
    Import-Module ps2exe -Force
}

function Compile-Script {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Output,
        [switch]$NoConsole
    )

    $args = @{
        InputFile  = $Source
        OutputFile = $Output
        Verbose    = $true
    }
    if ($NoConsole) { $args.NoConsole = $true }
    if ($IconPath -and (Test-Path $IconPath)) { $args.IconFile = $IconPath }

    Write-Host "Compiling $Source -> $Output" -ForegroundColor Cyan
    Invoke-PS2EXE @args
}

try {
    Ensure-Ps2Exe

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

    $core = Join-Path $PSScriptRoot "WBscrcpy.Core.psm1"
    $cli  = Join-Path $PSScriptRoot "WBscrcpy.ps1"
    $gui  = Join-Path $PSScriptRoot "WBscrcpy.Gui.ps1"

    foreach ($f in @($core, $cli, $gui)) {
        if (-not (Test-Path $f)) { throw "Required source not found: $f" }
    }

    # Module must sit next to the .exe at runtime
    Copy-Item -Path $core -Destination $OutDir -Force

    $buildGui = -not $Cli -or $Both
    $buildCli = $Cli -or $Both

    if ($buildGui) {
        Compile-Script -Source $gui -Output (Join-Path $OutDir "WBscrcpy.exe") -NoConsole
    }
    if ($buildCli) {
        Compile-Script -Source $cli -Output (Join-Path $OutDir "WBscrcpy-cli.exe")
    }

    Write-Host ""
    Write-Host "Done. Output:" -ForegroundColor Green
    Get-ChildItem $OutDir | ForEach-Object { Write-Host (" - {0}" -f $_.FullName) }
    Write-Host ""
    Write-Host "Run the .exe(s) directly. WBscrcpy.Core.psm1 must remain alongside the .exe." -ForegroundColor Yellow
}
catch {
    Write-Host "Build failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
