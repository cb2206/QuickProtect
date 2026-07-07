# QuickProtect for Windows & Linux (.NET / Avalonia port)

A cross-platform port of the macOS **QuickProtect** menu-bar app — a UniFi Protect
camera viewer — built on **.NET 8 + Avalonia + LibVLCSharp** so a single codebase
runs on **Windows and Linux** (and macOS, if ever wanted).

> The original macOS app is a Swift/SwiftUI/AppKit project in the repo root. This
> `desktop/` folder is the independent .NET reimplementation. Nothing here is
> shared with the Swift sources at the source level — only the behavior and the
> UniFi Protect protocol logic are ported.

## Why this stack

| Concern | macOS (Swift) | This port |
|---|---|---|
| Language / runtime | Swift | C# / .NET 8 (cross-platform, supersedes Mono) |
| UI | SwiftUI + AppKit | Avalonia 11 (Windows + Linux + macOS) |
| Tray / menu-bar | `NSStatusItem` | Avalonia `TrayIcon` |
| Video (RTSP→decode→render) | hand-written RTSP/RTP + VideoToolbox + `AVSampleBufferDisplayLayer` | **libVLC** via LibVLCSharp `VideoView` |
| RTSPS (RTSP-over-TLS) | own TLS socket with TOFU trust | loopback `RtspTlsTunnel` with the same TOFU trust (VLC 3 has no `rtsps` module) |
| Secrets | Keychain | DPAPI (Windows) / libsecret via `secret-tool`, 0600-file fallback (Linux) |
| Preferences | `UserDefaults` | JSON file in the user config dir |
| Start at login | `SMAppService` | Run registry key (Windows) / XDG autostart (Linux) |
| Cert trust | TOFU pin via `URLSession` delegate | TOFU pin via `HttpClientHandler` callback + `SslStream` callback (video) |

Choosing **libVLC** (rather than re-porting the Swift `RTSPClient`/`RTPParser`)
means RTSP, H.264/H.265 decode, and audio all come for free and work identically
on both targets. The one gap — VLC 3 cannot open `rtsps://` at all — is bridged
by `RtspTlsTunnel`: a 127.0.0.1 listener that pipes bytes over TLS to the
controller, so libVLC plays plain `rtsp://127.0.0.1:…` while the wire stays
encrypted and pinned.

## Project layout

```
desktop/
  QuickProtect.sln
  Directory.Build.props            # shared TFM/version
  src/
    QuickProtect.Core/             # portable domain layer (no UI, unit-tested)
      Models/      Camera, StreamQuality, PtzMapping, PtzBurstTimer,
                   SnapshotNaming, PinnedWindowGeometry
      Services/    ProtectService (dual UniFi API client), RtspTlsTunnel,
                   CertificateTrust (TOFU), AppSettings, IPreferences,
                   ISecretStore, ILaunchAtLogin, UpdateChecker, AppPaths, Log
    QuickProtect.App/              # Avalonia desktop app
      Program.cs, App.axaml(.cs)   # tray agent shell (≈ AppDelegate)
      ApertureIcon.cs              # the tray mark, drawn at runtime
      Platform/                    # global hotkey, launch-at-login, image clipboard
      Services/    VlcManager, PinnedWindowManager, SnapshotService
      ViewModels/  Main, CameraTile, Settings, Onboarding, Layout
      Views/       MainWindow (grid/focus), SettingsWindow, OnboardingWindow,
                   PinnedCameraWindow
      Localization/                # 7 languages from the macOS String Catalog
  tests/QuickProtect.Core.Tests/   # unit tests for the Core layer
  installer/QuickProtect.iss       # Inno Setup script (Windows)
  scripts/package-windows.ps1      # publish + build the Windows installer
```

## Build & run

Prerequisites: **.NET 8 SDK**. On **Linux** also install system libVLC
(`sudo apt install vlc` or `libvlc-dev`); on **Windows** the native binaries are
bundled via the `VideoLAN.LibVLC.Windows` NuGet package (x64/x86 only — on
Windows-on-ARM run the x64 build under emulation).

```bash
cd desktop
dotnet build QuickProtect.sln
dotnet test tests/QuickProtect.Core.Tests
dotnet run --project src/QuickProtect.App          # host-arch build
dotnet publish src/QuickProtect.App -c Release -r win-x64 --self-contained
```

The app launches as a tray agent (no main window). Left-click the tray icon to
open the camera grid; right-click for the menu. Open **Settings** to enter the
controller IP and Integration API key. `--open-panel` opens the grid immediately
(useful for testing).

Diagnostics: fatal errors land in `%APPDATA%\QuickProtect\crash.log`, libVLC
warnings/errors in `%APPDATA%\QuickProtect\vlc.log`.

## Packaging (Windows)

```powershell
winget install JRSoftware.InnoSetup   # once
powershell -File scripts/package-windows.ps1
# → dist/QuickProtect-Setup-<version>-x64.exe
```

## Feature parity status

The port is at feature parity with the macOS app for day-to-day use: tray shell,
live camera grid, focus view with PTZ (d-pad + keyboard, quick-tap min-burst),
pinned always-on-top windows, snapshots (folder or clipboard), secondary-lens
PiP, layout profiles, onboarding, global hotkey, notify-only update checks,
TOFU certificate pinning end-to-end (API + video), theming with accent colors,
and 7-language localization.

See [`PARITY.md`](PARITY.md) for the detailed feature-by-feature status and the
remaining polish items.
