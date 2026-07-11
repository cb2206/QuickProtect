# QuickProtect for Windows & Linux (.NET / Avalonia port)

A cross-platform port of the macOS **QuickProtect** menu-bar app — a UniFi Protect
camera viewer — built on **.NET 8 + Avalonia + LibVLCSharp** so a single codebase
runs on **Windows and Linux** (and macOS, if ever wanted).

> The original macOS app is a Swift/SwiftUI/AppKit project in `macos/`. This
> `dotnet/` folder is the independent .NET reimplementation. Nothing here is
> shared with the Swift sources at the source level — only the behavior and the
> UniFi Protect protocol logic are ported.

## Why this stack

| Concern | macOS (Swift) | This port |
|---|---|---|
| Language / runtime | Swift | C# / .NET 8 (cross-platform, supersedes Mono) |
| UI | SwiftUI + AppKit | Avalonia 11 (Windows + Linux + macOS) |
| Tray / menu-bar | `NSStatusItem` | Avalonia `TrayIcon` |
| Video (RTSP→decode→render) | hand-written RTSP/RTP + VideoToolbox + `AVSampleBufferDisplayLayer` | **libVLC** via LibVLCSharp `VideoView` |
| Secrets | Keychain | DPAPI (Windows) / 0600 file (Linux, libsecret TODO) |
| Preferences | `UserDefaults` | JSON file in the user config dir |
| Start at login | `SMAppService` | Run registry key (Windows) / XDG autostart (Linux) |
| Cert trust | TOFU pin via `URLSession` delegate | TOFU pin via `HttpClientHandler` callback |

Choosing **libVLC** (rather than re-porting the Swift `RTSPClient`/`RTPParser` +
Media Foundation) means RTSP, H.264/H.265 decode, and audio all come for free and
work identically on both targets.

## Project layout

```
dotnet/
  QuickProtect.sln
  Directory.Build.props            # shared TFM/version
  src/
    QuickProtect.Core/             # portable domain layer (no UI)
      Models/      Camera, StreamQuality
      Services/    ProtectService (dual UniFi API client), AppSettings,
                   CertificateTrust (TOFU), IPreferences, ISecretStore,
                   ILaunchAtLogin, AppPaths, Log
    QuickProtect.App/              # Avalonia desktop app
      Program.cs, App.axaml(.cs)   # tray agent shell (≈ AppDelegate)
      ApertureIcon.cs              # the tray mark, drawn at runtime
      Platform/                    # Windows/Linux launch-at-login
      Services/    VlcManager      # shared LibVLC instance
      ViewModels/  Main, CameraTile, Settings
      Views/       MainWindow (camera grid), SettingsWindow
```

## Build & run

Prerequisites: **.NET 8 SDK**. On **Linux** also install system libVLC
(`sudo apt install vlc` or `libvlc-dev`); on **Windows** the native binaries are
bundled via the `VideoLAN.LibVLC.Windows` NuGet package.

```bash
cd dotnet
dotnet build QuickProtect.sln
dotnet run --project src/QuickProtect.App
```

The app launches as a tray agent (no main window). Left-click the tray icon to
open the camera grid; right-click for the menu. Open **Settings** to enter the
controller IP and Integration API key.

## Feature parity status

Implemented (this pass):
- Tray agent shell, camera-grid panel, live RTSP/RTSPS playback via libVLC
- Dual UniFi Protect API: Integration API (list cameras, create/delete on-demand
  `rtsps-stream`, quality fallback ladder) + classic cookie API (login, PTZ moves,
  PTZ-capability enrichment)
- Trust-on-first-use certificate pinning (SHA-256 of the public key) with a
  "trust new certificate" action in Settings
- Settings: connection, default stream quality, optional PTZ credentials,
  launch-at-login
- Cross-platform persistence (JSON prefs) and secret storage (DPAPI / file)
- Layout-profile / hidden / order / size data model and pinned-camera state model

Not yet ported (tracked for follow-up — see `PARITY.md`):
- Focus (single-camera) view, fullscreen, fit/fill, snapshots
- On-screen PTZ d-pad + keyboard controls and the focus overlay
- Pinned always-on-top floating windows (data layer is ported; windowing is not)
- Onboarding wizard, App Store/update-checker nudges, auto-update checker
- Global hotkey registration (settings model exists; native hook does not)
- Secondary-lens picture-in-picture (doorbell package camera)
- Localization (the macOS app ships 7 languages; strings here are English-only)
- libsecret-backed secret store on Linux (currently a 0600 file)
```
