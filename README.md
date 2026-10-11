<div align="center">

# Macs Fan Control

**A native, open-source fan control and hardware monitoring app for macOS — written in Swift.**

Monitor every temperature, voltage, current, and power channel your Mac exposes, and take manual control of your fans through a code-signed privileged helper.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-black)
![M4](https://img.shields.io/badge/M4-fan%20control%20confirmed-brightgreen)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

**English** | [简体中文](README.zh-CN.md)

<img src="docs/screenshots/main-hardware.png" alt="Main window showing fan RPM and temperature sensors" width="720">

</div>

---

## Table of Contents

- [Highlights](#highlights)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Enabling Fan Control](#enabling-fan-control)
- [Features](#features)
- [Architecture](#architecture)
- [Safety](#safety)
- [Known Limitations](#known-limitations)
- [Development](#development)
- [Acknowledgements](#acknowledgements)
- [Disclaimer](#disclaimer)

## Highlights

- 💻 **Apple Silicon and Intel compatibility** — sensor catalogs and discovery, with capability-based fan control. Fan control confirmed by the user on M4 Mac mini (`Mac16,10`), macOS 27. Other models and recovery scenarios need hardware validation. See [compatibility](docs/COMPATIBILITY.md).
- 🌀 **Fan control** — constant RPM or sensor-based curves, applied live while you drag the slider.
- 🌡️ **Full telemetry** — enumerates available SMC `T*` / `V*` / `I*` / `P*` keys, HID sensors, and IOReport Energy Model channels.
- 📊 **Menu bar** — fan RPM and any sensor reading in fixed-width slots that never jitter.
- 🔐 **Secure helper** — root XPC helper with mutual code-signature verification; no paid developer account required.
- 🛟 **Fail-safe** — hands fans back to the system on sensor failure, write errors, disconnects, heartbeat timeout, sleep, and quit.
- 🧪 **Demo mode** — explore the whole UI with simulated fans without touching hardware.
- 📦 **Zero dependencies** — built with native macOS frameworks.

## Requirements

| | |
| --- | --- |
| OS | macOS 13 Ventura or later |
| Toolchain | Xcode / Swift 5.9 or later |
| Hardware | Apple Silicon M1–M6 or Intel Mac; fanless models provide monitoring only. See [compatibility and validation](docs/COMPATIBILITY.md). |

## Quick Start

Download a packaged app from [Releases](https://github.com/localhost-copilot/macs-fan-control-re/releases): `arm64` for Apple Silicon (including M6), or `x86_64` for Intel. Builds are ad-hoc signed and not notarized.

For the DMG, open the disk image and drag **Macs Fan Control** to **Applications**. ZIP downloads are also available.

To build from source:

```sh
git clone <repository-url> macs-fan-control
cd macs-fan-control

swift test                          # run unit tests
bash scripts/build-app.sh           # build and ad-hoc sign the .app
open "dist/Macs Fan Control.app"
```

You can also open `Package.swift` directly in Xcode.

### Try it without hardware access

```sh
# Full interactive demo with two simulated fans — never writes to hardware
open -n "dist/Macs Fan Control.app" --args --demo
```

### Command-line probing

```sh
# Read-only dump of fans, temperatures, voltages, currents, and power, then exit
swift run FanControl --probe

# Full inventory as JSON, including unavailable channels, raw HID values, and backing SMC keys
swift run FanControl --probe-json
```

## Enabling Fan Control

Reading sensors needs no privileges. Writing fan speeds requires a privileged helper, which the packaged app installs automatically on launch or the first time you change a fan. macOS asks for administrator authorization once. Status and removal live in **Preferences → Advanced**.

### Ad-hoc builds (default)

The default local build installs a root-owned copy of the app plus a LaunchDaemon. It stages the files in a root-only temporary directory, verifies the exact code-signature hashes (cdhash) of the app and helper, then registers the service. The XPC connection is bound to the current build in both directions, so **re-enable the helper after every rebuild**.

Installed files:

```
/Library/PrivilegedHelperTools/local.macsfancontrol.swift.helper.app
/Library/LaunchDaemons/local.macsfancontrol.swift.helper.plist
```

### Team-signed builds

With an Apple team signing identity, the helper is installed through `SMAppService` instead:

```sh
SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' bash scripts/build-app.sh
# An Apple Development identity also works for testing.
```

Move the app to a stable location (for example `/Applications/Macs Fan Control.app`), enable the helper, and approve it under **System Settings → General → Login Items**. The app and helper must share a Team ID. Before switching installation methods, remove the old helper with **Remove helper…** from the previous build.

### Removing the helper

**Preferences → Advanced → Remove helper…** restores automatic control first, then unregisters the service.

> [!WARNING]
> Do not let another fan control tool drive the same fan at the same time.

## Features

<details open>
<summary><b>Main window & fan control</b></summary>

- Resizable two-pane window: fans (min / current / max RPM, Auto / Custom) and sensors, with double-click and context menus.
- **Constant RPM** via slider or numeric input.
- **Sensor-based** control with start / max temperatures, live curve preview showing the current operating point, and input validation.
- Changes take effect immediately; **Cancel** restores the previous settings.
- CPU / GPU Maximum Temperature shows the highest currently available reading among each family's identified channels, and can drive menu bar readings and fan control. These are current maxima, not historical peaks; losing every reading makes the value unavailable and returns temperature-based control to automatic.
- Presets: Automatic, Full blast, and custom presets (save / rename / delete / apply). The last successfully applied control settings also persist without saving a preset, and are restored after hardware discovery on launch, including after upgrades. Selecting Automatic clears custom control for the next launch.

</details>

<details>
<summary><b>Menu bar</b></summary>

- Monochrome, color, or no icon; fan RPM and a chosen sensor reading.
- Fixed-width value slots so the item never shifts as numbers change.
- Color icon turns orange under manual control; high temperatures are highlighted.
- Preset switching, per-fan control, show / hide window, and quit.

</details>

<details>
<summary><b>Sensors & telemetry</b></summary>

- **SMC**: automatic enumeration of `T*` / `V*` / `I*` / `P*` keys, supporting float and valid signed / unsigned 16-bit fixed-point encodings. Unknown keys and unavailable states are kept; rediscovery runs every minute.
- **HID**: temperature, voltage, and current. Same-named PMU channels are disambiguated by `LocationID`; electrical channels with broken HID encoding are read through their matching SMC key. Raw HID values are retained for diagnostics.
- **IOReport Energy Model**: every discoverable channel, converted to watts from two energy samples. The first sample, counter resets, and sleep gaps show a waiting state. Overlapping channels are never summed into a fake system total.
- Classified by type, unit, source, channel count, and unavailability reason. Only valid temperatures can drive fan curves.
- Default list shows named sensors and group averages; **Show all raw channels** reveals everything. `Mac18,5` additionally gets *inferred* CPU / GPU averages.

</details>

<details>
<summary><b>Preferences</b></summary>

- Toolbar-style window: **General**, **T° Sensors**, **Menu bar display**, and **Advanced** (helper management and diagnostics).
- Launch at login minimized, Dock icon toggle, Celsius / Fahrenheit, precise readings, sensor visibility.
- English and Simplified Chinese UI.
- Local ZIP diagnostics export — nothing is uploaded and disk serial numbers are not collected.

</details>

## Architecture

```mermaid
flowchart LR
    subgraph App["FanControl.app (user)"]
        UI["SwiftUI / AppKit views"] --> Model["AppModel"]
        Model --> Monitor["HardwareMonitor<br/>(background sampling)"]
        Model --> Client["HelperClient"]
    end
    subgraph Core["FanCore"]
        SMC["AppleSMC"]
        HID["HIDSensorReader"]
        Power["PowerReader (IOReport)"]
        Ctrl["TemperatureController"]
    end
    Monitor --> SMC & HID & Power
    Client -- "XPC (mutual code-sign check)" --> Helper["FanHelper (root)"]
    Helper --> Session["ControlSession"] --> SMC
    Session --> Ctrl
```

```
Sources/
├── FanCore/        SMC ABI, HID reader, IOReport power, model database, controller, control session, XPC protocol
├── FanControl/     App: AppModel, HardwareMonitor, HelperClient, LocalHelperInstaller,
│                   MainView, FanControlSheet, CurvePreview, PreferencesView, StatusItemRenderer, Theme
└── FanHelper/      Signed root XPC service; serializes hardware access, ticks every 1.5 s
Tests/
├── FanCoreTests/   Decoding, input bounds, controller clamping, stale fallback, sensor failure, partial write recovery
└── FanControlTests/ App and installer tests
scripts/
├── build-app.sh    Build, bundle, and sign the .app
└── make-icon.swift App icon drawn in code
docs/
├── COMPATIBILITY.md Hardware validation status and troubleshooting
└── screenshots/    README screenshot
```

The helper discovers `F{i}md` / `F{i}Md` mode keys or the legacy Intel `FS! ` bitmask and writes float or `fpe2` target RPM. Firmware mode 3 is system control. Per-fan mode changes (including automatic recovery) and target writes retry briefly when successful writes have mismatched readback. If manual mode still fails or returns `0x82`, machines exposing `Ftst` use the unlock path with bounded retries. An unlock acquired by this connection is released after its last controlled fan returns to automatic mode; failed recovery remains retryable. Mode and target writes are read back before reporting success.

## Safety

The app is designed to fail toward the system's automatic fan control:

| Event | Behavior |
| --- | --- |
| Sensor driving a curve fails | Fan returns to automatic |
| SMC write fails | Fan returns to automatic; restore retried until it succeeds |
| Client disconnects / heartbeat times out | Helper releases all fans |
| Helper receives `SIGTERM` | Fans restored to automatic |
| System sleep or app quit | App releases the fans it controls |
| App launch | Restore the last applied settings after hardware discovery and validation; report failures without repeated restore attempts |

Closing the main window only hides the app to the menu bar; quitting releases control.

## Known Limitations

- **Unofficial.** This is an independent project and is not affiliated with CrystalIDEA.
- **Controller** implements temperature bands, directional hysteresis, ramping, and 31 s refresh.
- **Storage / external sensors.** SSD temperature comes from system HID / NAND channels. Separate SATA / NVMe SMART, Thunderbolt disks, and eGPU temperatures are not implemented.
- **"All" means publicly enumerable.** Firmware-hidden sensors are inaccessible. HID and SMC may expose the same physical sensor, so the channel count is not the number of physical sensors. Missing Apple Silicon CPU / GPU mappings use inferred `Tp*` / `Te*` / `Tg*` groups, preserving existing model-specific mappings. These are not verified core identities or package temperatures.
- **Low temperatures.** Some Apple Silicon hardware refuses to spin fans up manually when cold.
- **Localization.** English and Simplified Chinese only.
- **Not notarized.** M4 Mac mini fan control is user-confirmed; other models and post-sleep recovery still need real-hardware testing. See [compatibility](docs/COMPATIBILITY.md).

## Development

```sh
swift build                         # debug build
swift test                          # run all tests
CONFIGURATION=debug bash scripts/build-app.sh
bash scripts/check-packaged-app.sh  # check resources outside the build directory
bash scripts/build-dmg.sh           # create a drag-to-install disk image
```

| UserDefaults domain | Used by |
| --- | --- |
| `local.macsfancontrol.swift` | Normal launches |
| `local.macsfancontrol.swift.demo` | `--demo` launches |

In demo mode, **Use real sensors** in the main window switches back to real hardware.

Contributions are welcome. Please keep hardware writes behind the helper, add tests for new decoding or control logic, and update `docs/COMPATIBILITY.md` when verifying another model.

## Acknowledgements

- [Macs Fan Control](https://crystalidea.com/macs-fan-control) by CrystalIDEA — inspiration for the interface and interaction design.
- [Stats](https://github.com/exelban/stats) — reference for HID usage pages, event types, and IOReport signatures.
- [Chromium `m1_sensors_mac.mm`](https://chromium.googlesource.com/chromium/src/+/refs/tags/123.0.6285.0/components/power_metrics/m1_sensors_mac.mm) — IOKit HID C signatures.
- [Mac-mini-M6-fan-control-LLM](https://github.com/HDZucht/Mac-mini-M6-fan-control-LLM) — notes on the lowercase `F0md` mode key.

## Disclaimer

> [!CAUTION]
> This software talks to private, undocumented SMC / HID interfaces that are not stable macOS SDK contracts. Changing fan speeds can affect thermals and hardware lifespan. **Use at your own risk**, and verify reading, authorization, and recovery on your own model before relying on it.

The five XML files in `Sources/FanCore/Resources` (sensor names, model aliases, and fan locations) come from CrystalIDEA's Macs Fan Control. They are **not** original to this project and no redistribution license is claimed for them. All Swift source code is an independent implementation.

"Macs Fan Control" is a trademark of CrystalIDEA Software. This project is not affiliated with or endorsed by CrystalIDEA.
