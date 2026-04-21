<div align="center">

# WB's scrcpy Launcher

**Polished PowerShell + WinForms GUI wrapper for [scrcpy](https://github.com/Genymobile/scrcpy).**
Mirror and control Android devices over USB or Wi-Fi with presets, health checks, and either a guided CLI or a click-friendly GUI — also packageable as a standalone `.exe`.

[![Platform](https://img.shields.io/badge/platform-Windows-blue?logo=windows)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blueviolet?logo=powershell)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

---

## Contents

- [What you get](#what-you-get)
- [Project files](#project-files)
- [Requirements](#requirements)
- [Installation](#installation)
- [Three ways to run](#three-ways-to-run)
- [GUI walkthrough](#gui-walkthrough)
- [CLI usage](#cli-usage)
  - [Parameters](#parameters)
  - [Display modes](#display-modes)
- [Preset system](#preset-system)
- [Health check](#health-check)
- [Building the .exe](#building-the-exe)
- [Architecture](#architecture)
- [License](#license)

---

## What you get

| Front-end | File | Best for |
|---|---|---|
| **GUI** | `WBscrcpy.Gui.ps1` (and `WBscrcpy.exe` after build) | Everyone. Click, configure, launch. |
| **CLI** | `WBscrcpy.ps1` | Scripting, hotkeys, automation. |
| **Core lib** | `WBscrcpy.Core.psm1` | Shared logic — both front-ends import it. |

Common features across both:

- USB and Wi-Fi/Ethernet (TCP/IP) connections, auto-`adb connect` with retry.
- 6 display presets — normal, fullscreen, screen-off, borderless, high quality, custom DPI.
- Per-session FPS cap, bitrate, codec (H.264 / H.265 / AV1).
- Custom display density (DPI) for desktop-style layouts; auto-restore on exit.
- Stay-awake wake-lock with **guaranteed cleanup** even on Ctrl-C / GUI close.
- Named presets stored in `WBscrcpy.presets.json` (load, save, list, delete).
- Health-check diagnostics for `adb` / `scrcpy` / network / device state.
- Multi-device aware — pick from a list or target by serial.

---

## Project files

```
WBs-Scrcpy/
├── WBscrcpy.Core.psm1   ← all reusable logic (ADB, presets, scrcpy launch)
├── WBscrcpy.ps1         ← CLI front-end
├── WBscrcpy.Gui.ps1     ← WinForms GUI front-end
├── Build-Exe.ps1        ← packages the GUI/CLI into standalone .exe via ps2exe
├── README.md
├── LICENSE
└── .gitignore
```

---

## Requirements

| Tool | Notes |
|---|---|
| **Windows 10/11** | WinForms GUI is Windows-only. |
| **PowerShell 5.1+** | Built into Windows. PowerShell 7+ also works. |
| **[scrcpy](https://github.com/Genymobile/scrcpy)** | Must be on `PATH`. `winget install Genymobile.scrcpy` works. |
| **[ADB](https://developer.android.com/tools/adb)** | Bundled with scrcpy releases or installed standalone. Must be on `PATH`. |
| **[ps2exe](https://github.com/MScholtes/PS2EXE)** *(optional)* | Only needed to build the `.exe`. `Build-Exe.ps1` installs it for you. |

---

## Installation

```powershell
git clone https://github.com/your-username/WBs-Scrcpy.git
cd WBs-Scrcpy

# Verify dependencies
Get-Command scrcpy, adb
.\WBscrcpy.ps1 -HealthCheck
```

> **Execution policy** — if scripts are blocked:
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

---

## Three ways to run

```powershell
# 1. CLI guided (interactive menus)
.\WBscrcpy.ps1

# 2. GUI (WinForms window)
.\WBscrcpy.Gui.ps1
# or, from the CLI:
.\WBscrcpy.ps1 -Gui

# 3. Standalone .exe (after running Build-Exe.ps1)
.\dist\WBscrcpy.exe
```

---

## GUI walkthrough

Three tabs:

**Launch tab**
- Choose USB or Network. The Device dropdown auto-populates and filters by connection type.
- For Network: type IP/port and hit **Connect TCP** to `adb connect` first.
- Pick a display mode. Density and "Reset on exit" only enable for mode 6.
- Optional FPS cap, bitrate, codec.
- **Launch scrcpy** spawns the process; **Stop** kills it. Wake-lock and density are cleaned up automatically when the process exits.
- Live log panel at the bottom.

**Presets tab**
- See all saved presets.
- **Load into form** → applies to the Launch tab.
- **Save form as…** → prompts for a name and writes to `WBscrcpy.presets.json`.
- **Delete selected** → removes a preset.

**Health tab**
- Click **Run health check** — runs every diagnostic and shows results in a colour-coded grid.

---

## CLI usage

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Mode` | `Interactive` \| `USB` \| `Network` | `Interactive` | How to connect. |
| `-DefaultIP` | `string` | `192.168.1.220` | Fallback IP. |
| `-DefaultPort` | `int` | `5555` | Fallback port. |
| `-IP` | `string` | — | Device IP for Network mode. |
| `-Port` | `int` | — | ADB TCP port. |
| `-DeviceSerial` | `string` | — | Target a specific device. For network: `IP:port`. |
| `-DisplayMode` | `1`–`6` | `1` | Display layout. |
| `-MaxFps` | `int` | — | FPS cap (15-144). |
| `-Bitrate` | `string` | — | Video bitrate, e.g. `8M`. |
| `-Codec` | `h264` \| `h265` \| `av1` | — | Video codec. |
| `-Density` | `int` | — | DPI 120-640 (required for mode 6). |
| `-ResetDensityOnExit` | `switch` | — | Restore DPI when scrcpy exits. |
| `-LoadPreset` | `string` | — | Load preset; explicit params still override. |
| `-SavePreset` | `string` | — | Save the resolved config under this name. |
| `-NoLaunch` | `switch` | — | Do not start scrcpy after saving (use with `-SavePreset`). |
| `-ListPresets` | `switch` | — | Print presets and exit. |
| `-HealthCheck` | `switch` | — | Run diagnostics and exit. |
| `-NoWakeLock` | `switch` | — | Skip stay-awake. |
| `-NoInteractiveTuning` | `switch` | — | Skip the FPS/codec/bitrate prompt. |
| `-Gui` | `switch` | — | Launch the GUI instead. |

### Display modes

| Mode | Description | scrcpy flags |
|:---:|---|---|
| `1` | Normal window | *(none)* |
| `2` | Fullscreen | `--fullscreen` |
| `3` | Fullscreen + Screen OFF | `--fullscreen --turn-screen-off` |
| `4` | Borderless fullscreen | `--fullscreen --window-borderless` |
| `5` | High quality (1080p / 8 Mbps default) | `--fullscreen --max-size 1920 --video-bit-rate 8M` (your `-Bitrate` overrides) |
| `6` | Custom DPI + Fullscreen + Screen OFF | `--fullscreen --turn-screen-off` + `adb shell wm density <Density>` |

### Examples

```powershell
# USB, borderless fullscreen
.\WBscrcpy.ps1 -Mode USB -DisplayMode 4

# Wi-Fi, fullscreen + screen off, 60 fps, H.265
.\WBscrcpy.ps1 -Mode Network -IP 192.168.1.42 -DisplayMode 3 -MaxFps 60 -Codec h265

# Load preset then override codec
.\WBscrcpy.ps1 -LoadPreset "Work" -Codec h265

# Save a preset WITHOUT launching scrcpy
.\WBscrcpy.ps1 -Mode USB -DisplayMode 5 -MaxFps 120 -SavePreset "HighFPS" -NoLaunch

# Custom DPI session, restore DPI on exit
.\WBscrcpy.ps1 -Mode USB -DisplayMode 6 -Density 240 -ResetDensityOnExit

# Target specific device
.\WBscrcpy.ps1 -Mode USB -DeviceSerial "ABCDEF123" -DisplayMode 1

# Open the GUI
.\WBscrcpy.ps1 -Gui
```

---

## Preset system

Presets live in `WBscrcpy.presets.json` next to the script (gitignored). Both GUI and CLI share the same file.

**Resolution order:**
1. `New-LaunchConfig` defaults
2. `-LoadPreset` (CLI) / "Load into form" (GUI)
3. Explicit CLI parameters or GUI form values

So a preset acts as a base; whatever you specify on top wins.

In **interactive CLI mode**, if you load a preset its values are *kept* — the script does not re-prompt for everything. (Previous releases re-asked and silently overwrote presets — fixed.)

---

## Health check

```powershell
.\WBscrcpy.ps1 -HealthCheck
.\WBscrcpy.ps1 -HealthCheck -IP 192.168.1.50 -Port 5555
```

Checks: `adb` in PATH · `scrcpy` in PATH · ADB server start · device list · ping · TCP reachability.

GUI: same checks via the **Health** tab.

---

## Building the .exe

```powershell
# GUI exe (default, no console window)
.\Build-Exe.ps1

# CLI exe (console window)
.\Build-Exe.ps1 -Cli

# Both
.\Build-Exe.ps1 -Both

# Custom output dir / icon
.\Build-Exe.ps1 -OutDir "C:\Apps\WBscrcpy" -IconPath ".\icon.ico"
```

Output lives in `dist/`:

```
dist/
├── WBscrcpy.exe          ← GUI (windowless)
├── WBscrcpy-cli.exe      ← CLI (with -Both)
└── WBscrcpy.Core.psm1    ← required at runtime, copied automatically
```

Notes:

- The build uses [ps2exe](https://github.com/MScholtes/PS2EXE). `Build-Exe.ps1` installs it for the current user if missing.
- **`WBscrcpy.Core.psm1` must stay next to the `.exe`** — it is imported at runtime.
- The `.exe` is just a wrapper that hosts PowerShell; you still need `adb` and `scrcpy` on `PATH` (or in the same folder) on the target machine.
- Pin `WBscrcpy.exe` to your taskbar/Start menu for one-click launches.

---

## Architecture

```
┌─────────────────────┐         ┌─────────────────────┐
│   WBscrcpy.ps1      │         │   WBscrcpy.Gui.ps1  │
│   (CLI front-end)   │         │   (WinForms front)  │
└──────────┬──────────┘         └──────────┬──────────┘
           │ Import-Module                  │ Import-Module
           ▼                                ▼
┌─────────────────────────────────────────────────────┐
│              WBscrcpy.Core.psm1                     │
│   Get-AdbDevice • Resolve-UsbDevice •               │
│   Connect-AdbNetworkDevice • Build-ScrcpyArgs •     │
│   Invoke-Scrcpy (try/finally cleanup) •             │
│   Import/Export-Presets • Invoke-HealthCheck        │
└──────────────────────┬──────────────────────────────┘
                       │ shells out
                       ▼
                ┌─────────────┐    ┌─────────────┐
                │   adb.exe   │    │ scrcpy.exe  │
                └─────────────┘    └─────────────┘
```

Launch flow inside `Invoke-Scrcpy`:

1. Validate `adb` + `scrcpy` on PATH, start ADB server.
2. Resolve device — USB list pick or `adb connect IP:Port` (with retry).
3. Disconnect stale TCP devices (logged).
4. Apply custom DPI if mode 6.
5. Enable stay-awake.
6. `Start-Process scrcpy` and wait (or return process for the GUI).
7. **`finally`**: disable stay-awake, reset DPI if requested. Runs even on crash / Ctrl-C / GUI Stop.

---

## License

MIT — see [LICENSE](LICENSE).

---

<div align="center">
Made with ☕ and way too many ADB flags.
</div>
