<div align="center">

# WB's scrcpy Launcher

**A polished, feature-rich PowerShell wrapper for [scrcpy](https://github.com/Genymobile/scrcpy) — mirror and control Android devices over USB or Wi-Fi with presets, health checks, and an interactive guided setup.**

[![Platform](https://img.shields.io/badge/platform-Windows-blue?logo=windows)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blueviolet?logo=powershell)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
  - [Parameters](#parameters)
  - [Display Modes](#display-modes)
  - [Connection Modes](#connection-modes)
- [Preset System](#preset-system)
- [Health Check](#health-check)
- [Examples](#examples)
- [How It Works](#how-it-works)
- [License](#license)

---

## Overview

`WBscrcpy.ps1` takes the friction out of launching scrcpy. Instead of memorising a wall of command-line flags every time you want to mirror your phone, this script walks you through a guided menu, remembers your favourite setups as named presets, and handles the tedious ADB plumbing — connecting, selecting devices, applying wake locks, restoring density — automatically.

---

## Features

| Category | Capability |
|---|---|
| **Connection** | USB and Wi-Fi/Ethernet (TCP/IP) with automatic ADB connect/disconnect |
| **Display** | 6 built-in display modes from a simple window to borderless fullscreen with screen-off |
| **Performance** | Per-session FPS cap, bitrate, and codec selection (H.264 / H.265 / AV1) |
| **Density** | Set a custom display DPI for desktop-like layouts; optionally auto-reset on exit |
| **Wake lock** | Keeps the device screen awake while scrcpy is running; restores state on exit |
| **Preset system** | Save, load, and list named configurations as a local JSON file |
| **Health check** | Validates `adb`/`scrcpy` in PATH, ADB server, connected devices, and TCP reachability |
| **Non-interactive** | Fully scriptable via parameters — no prompts, no menus |
| **Multi-device** | Lists all ready devices and lets you pick, or target one by serial |

---

## Requirements

| Tool | Notes |
|---|---|
| **PowerShell 5.1+** | Ships with Windows 10/11. PowerShell 7+ also fully supported. |
| **[scrcpy](https://github.com/Genymobile/scrcpy)** | Must be available in `PATH`. Install via `winget install Genymobile.scrcpy` or the official release. |
| **[ADB (Android Debug Bridge)](https://developer.android.com/tools/adb)** | Bundled with scrcpy releases, or install Android Platform Tools separately. Must be in `PATH`. |
| **Android device** | USB debugging enabled. For Wi-Fi, ADB over TCP must be active on the device. |

---

## Installation

1. Clone or download this repository:
   ```powershell
   git clone https://github.com/your-username/WBs-Scrcpy.git
   cd WBs-Scrcpy
   ```

2. Ensure `scrcpy` and `adb` are on your `PATH`:
   ```powershell
   Get-Command scrcpy, adb
   ```

3. *(Optional)* Run the health check to confirm everything is wired up correctly:
   ```powershell
   .\WBscrcpy.ps1 -HealthCheck
   ```

> **Execution Policy** — if PowerShell blocks the script, run:
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

---

## Quick Start

**Interactive guided launch (recommended for first use):**
```powershell
.\WBscrcpy.ps1
```
The script will walk you through choosing a connection type, display mode, and optional performance tuning — then offer to save your choices as a named preset.

**Launch straight from a saved preset:**
```powershell
.\WBscrcpy.ps1 -LoadPreset "MyPhone"
```

**One-liner USB launch, fullscreen, no prompts:**
```powershell
.\WBscrcpy.ps1 -Mode USB -DisplayMode 2
```

---

## Usage

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Mode` | `Interactive` \| `USB` \| `Network` | `Interactive` | How to connect. `Interactive` shows guided menus. |
| `-DefaultIP` | `string` | `192.168.1.220` | Fallback IP used when none is specified. |
| `-DefaultPort` | `int` | `5555` | Fallback ADB TCP port. |
| `-IP` | `string` | — | Device IP for Network mode. |
| `-Port` | `int` | — | ADB TCP port for Network mode. |
| `-DeviceSerial` | `string` | — | Target a specific device by its ADB serial. |
| `-DisplayMode` | `1`–`6` | `1` | Display layout preset (see table below). |
| `-MaxFps` | `int` | — | Cap the frame rate (e.g. `60`). |
| `-Bitrate` | `string` | — | Video bitrate, e.g. `8M`, `4M`. |
| `-Codec` | `h264` \| `h265` \| `av1` | — | Video codec passed to scrcpy. |
| `-Density` | `int` | — | Custom DPI (120–640). Required for display mode `6`. |
| `-ResetDensityOnExit` | `switch` | — | Restore device DPI to its default when scrcpy closes. |
| `-LoadPreset` | `string` | — | Name of a saved preset to load before launch. |
| `-SavePreset` | `string` | — | Save the current configuration under this name. |
| `-ListPresets` | `switch` | — | Print all saved presets and exit. |
| `-HealthCheck` | `switch` | — | Run diagnostics (PATH, ADB server, ping, TCP) and exit. |
| `-NoWakeLock` | `switch` | — | Skip enabling stay-awake; the device screen may dim. |
| `-NoInteractiveTuning` | `switch` | — | Suppress the FPS/bitrate/codec prompt in Interactive mode. |

---

### Display Modes

| Mode | Description | scrcpy flags applied |
|:---:|---|---|
| `1` | **Normal window** — resizable, decorated | *(none)* |
| `2` | **Fullscreen** | `--fullscreen` |
| `3` | **Fullscreen + Screen OFF** — mirror while the device display stays dark | `--fullscreen --turn-screen-off` |
| `4` | **Borderless fullscreen** — no window chrome | `--fullscreen --window-borderless` |
| `5` | **High quality** — 1080p cap, 8 Mbps bitrate | `--fullscreen --max-size 1920 --video-bit-rate 8M` |
| `6` | **Custom density** — sets a DPI on the device then mirrors fullscreen with screen off | `--fullscreen --turn-screen-off` + `adb wm density <value>` |

---

### Connection Modes

**USB**
- Detects all connected USB devices in `device` state.
- Auto-selects if only one device is present; presents a numbered list otherwise.
- Warns about devices that are in `unauthorized`, `offline`, or other non-ready states.

**Network (Wi-Fi / Ethernet)**
- Calls `adb connect <IP>:<port>` and verifies the device reaches `device` state.
- Automatically disconnects any other stale TCP ADB sessions before launching scrcpy.
- Validates the IPv4 address and port range before attempting a connection.

---

## Preset System

Presets are saved to `WBscrcpy.presets.json` in the same directory as the script. This file is excluded from source control via `.gitignore` so your personal device settings stay local.

**Save a preset interactively:** the script will ask at the end of the guided flow.

**Save a preset non-interactively:**
```powershell
.\WBscrcpy.ps1 -Mode Network -IP 192.168.1.50 -DisplayMode 3 -MaxFps 60 -SavePreset "LivingRoomTV"
```

**Load a preset:**
```powershell
.\WBscrcpy.ps1 -LoadPreset "LivingRoomTV"
```

**List all presets:**
```powershell
.\WBscrcpy.ps1 -ListPresets
```

**How presets and parameters interact:**
1. The preset is loaded first, populating all stored values.
2. Any explicit parameters you pass on the command line then *override* the preset values.

This means you can use a preset as a base and tweak one thing without redefining everything:
```powershell
# Use the "LivingRoomTV" preset but swap to H.265 just this once
.\WBscrcpy.ps1 -LoadPreset "LivingRoomTV" -Codec h265
```

---

## Health Check

The `-HealthCheck` switch runs a quick diagnostics pass without launching scrcpy:

```powershell
.\WBscrcpy.ps1 -HealthCheck
# Or target a specific IP/port
.\WBscrcpy.ps1 -HealthCheck -IP 192.168.1.50 -Port 5555
```

Checks performed:

- `adb` present in `PATH`
- `scrcpy` present in `PATH`
- ADB server can start
- List of currently connected ADB devices
- ICMP ping to the target IP (if provided)
- TCP port reachability test to `<IP>:<Port>`

---

## Examples

```powershell
# Interactive guided launch (default)
.\WBscrcpy.ps1

# USB, borderless fullscreen, no prompts
.\WBscrcpy.ps1 -Mode USB -DisplayMode 4

# Wi-Fi, fullscreen + screen off, 60 fps, H.265
.\WBscrcpy.ps1 -Mode Network -IP 192.168.1.42 -DisplayMode 3 -MaxFps 60 -Codec h265

# Load a preset then override the display mode
.\WBscrcpy.ps1 -LoadPreset "Work" -DisplayMode 2

# Save a new preset without launching (use -NoWakeLock as a dummy param to stay non-interactive)
.\WBscrcpy.ps1 -Mode USB -DisplayMode 5 -MaxFps 120 -SavePreset "HighFPS" -NoWakeLock

# Display mode 6: custom 240 DPI, restore DPI when done
.\WBscrcpy.ps1 -Mode USB -DisplayMode 6 -Density 240 -ResetDensityOnExit

# Target a specific device by serial (useful with multiple devices)
.\WBscrcpy.ps1 -Mode USB -DeviceSerial "emulator-5554" -DisplayMode 1

# Health check against default IP
.\WBscrcpy.ps1 -HealthCheck

# List all saved presets
.\WBscrcpy.ps1 -ListPresets
```

---

## How It Works

```
┌──────────────────────────────────────────────────────┐
│                    WBscrcpy.ps1                      │
│                                                      │
│  1. Load presets from WBscrcpy.presets.json          │
│  2. Apply -LoadPreset (if given)                     │
│  3. Override with any explicit CLI parameters        │
│  4. Interactive mode → guided menus                  │
│     Non-interactive → validate required fields       │
│  5. Save preset (if requested)                       │
│  6. Resolve device serial                            │
│     ├─ USB  → adb devices, pick from list            │
│     └─ Network → adb connect <IP>:<port>             │
│  7. Disconnect other stale TCP sessions              │
│  8. Apply custom density (mode 6)                    │
│  9. Build scrcpy argument list                       │
│ 10. Enable stay-awake (unless -NoWakeLock)           │
│ 11. Launch scrcpy and wait for exit                  │
│ 12. Disable stay-awake                               │
│ 13. Reset density (mode 6 + -ResetDensityOnExit)     │
└──────────────────────────────────────────────────────┘
```

---

## License

Distributed under the [MIT License](LICENSE).

---

<div align="center">
Made with ☕ and way too many ADB flags.
</div>
