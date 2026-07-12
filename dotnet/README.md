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
| Secrets | Keychain | DPAPI (Windows) / libsecret via `secret-tool` with 0600-file fallback (Linux) |
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
      Models/      Camera, StreamQuality, Ptz (d-pad/keyboard→axis mapping),
                   PinnedWindowGeometry, SnapshotNaming
      Services/    ProtectService (dual UniFi API client), AppSettings,
                   CertificateTrust (TOFU), UpdateChecker, VersionCompare,
                   IPreferences, ISecretStore, ILaunchAtLogin, AppPaths, Log
    QuickProtect.App/              # Avalonia desktop app
      Program.cs, App.axaml(.cs)   # tray agent shell (≈ AppDelegate)
      ApertureIcon.cs              # the tray mark, drawn at runtime
      Localization/                # Loc + {loc:Loc} markup, embedded .resx (7 languages)
      Platform/                    # launch-at-login, global hotkey, URL opener
      Services/    VlcManager (shared libVLC), PinnedWindowManager, SnapshotService
      ViewModels/  Main, CameraTile/CameraRow, Layout, Settings, Onboarding
      Views/       MainWindow (grid + focus view), SettingsWindow,
                   OnboardingWindow, PinnedCameraWindow
  tests/
    QuickProtect.Core.Tests/       # unit tests over the Core logic
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

Or use the repo scripts, which build, replace any running instance, and launch:
`scripts\windows\run.ps1` (Windows) / `scripts/linux/run.sh` (Linux).

The app launches as a tray agent (no main window). Left-click the tray icon to
open the camera grid; right-click for the menu. Open **Settings** to enter the
controller IP and Integration API key.

## Feature parity status

Feature-complete against the macOS app for the targeted scope — the full
item-by-item list lives in [`docs/PARITY.md`](../docs/PARITY.md). Highlights:

- Tray agent shell, camera-grid panel with search/profile switcher/stream-count
  pill, live RTSP/RTSPS playback via libVLC (graceful degradation if libVLC
  can't load)
- Focus (single-camera) view with fullscreen, fit/fill, mute, snapshots
  (S key / button, configurable destination), and secondary-lens PiP
- PTZ: on-screen d-pad + zoom pill and keyboard controls (Core-tested axis
  mapping matching the macOS sign conventions)
- Pinned always-on-top floating windows — aspect-locked resize, frame
  persistence, restore-on-launch
- Dual UniFi Protect API: Integration API (list cameras, create/delete on-demand
  `rtsps-stream`, quality fallback ladder) + classic cookie API (login, PTZ moves,
  PTZ-capability enrichment); trust-on-first-use certificate pinning with a
  "trust new certificate" action in Settings
- Cameras & Layout settings (profiles, show/hide, size, order), first-run
  onboarding wizard, global hotkey (native on Windows; documented no-op on
  Linux), notify-only update checker, customizable accent color
- Localization in all 7 languages (en/de/fr/es/nl/it/pt-BR) via embedded .resx
- Secret storage: DPAPI (Windows) / libsecret via `secret-tool` with 0600-file
  fallback (Linux); JSON prefs for everything else

Remaining lower-priority gaps (tracked in [`docs/PARITY.md`](../docs/PARITY.md)):
light/auto theme (dark-only today), true-fullscreen HUD, snapshot-to-clipboard,
plain-RTSP toggle, in-grid drag-to-reorder, Aurora visual polish, full string
coverage.

Known issue: a crash on Windows 11 ARM under x64 emulation is being investigated
— see [`docs/HANDOFF.md`](../docs/HANDOFF.md) (fatal exceptions land in
`%APPDATA%\QuickProtect\crash.log`).
