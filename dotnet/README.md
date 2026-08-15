# QuickProtect for Windows & Linux (.NET / Avalonia port)

A cross-platform port of the macOS **QuickProtect** menu-bar app — a UniFi Protect
camera viewer — built on **.NET 8 + Avalonia + FFmpeg** so a single codebase
runs on **Windows and Linux** (and macOS, if ever wanted).

> The original macOS app is a Swift/SwiftUI/AppKit project in `macos/`. This
> `dotnet/` folder is the independent .NET reimplementation. Nothing here is
> shared with the Swift sources at the source level — only the behavior and the
> UniFi Protect protocol logic are ported.

The Windows build ships on the
[**Microsoft Store**](https://apps.microsoft.com/detail/9n7q858g3tk5) (signed,
auto-updating) and as a free unsigned installer on
[GitHub Releases](https://github.com/cb2206/QuickProtect/releases); the Linux
build ships (since 1.3.1) as a self-contained x64 tarball on the same releases
(see [`PARITY.md`](../docs/PARITY.md) → Distribution for the channel details).

## Why this stack

| Concern | macOS (Swift) | This port |
|---|---|---|
| Language / runtime | Swift | C# / .NET 8 (cross-platform, supersedes Mono) |
| UI | SwiftUI + AppKit | Avalonia 11 (Windows + Linux + macOS) |
| Tray / menu-bar | `NSStatusItem` | Avalonia `TrayIcon` |
| Video (RTSP→decode→render) | hand-written RTSP/RTP + VideoToolbox + `AVSampleBufferDisplayLayer` | **FFmpeg** (via FFmpeg.AutoGen) demux + decode, frames composited by Avalonia `VideoSurface` |
| RTSPS (RTSP-over-TLS) | own TLS socket with TOFU trust | loopback `RtspTlsTunnel` with the same TOFU trust (FFmpeg's TLS can't do the app's TOFU pinning) |
| Secrets | Keychain | DPAPI (Windows) / libsecret via `secret-tool`, 0600-file fallback (Linux) |
| Preferences | `UserDefaults` | JSON file in the user config dir |
| Start at login | `SMAppService` | Run registry key (Windows) / XDG autostart (Linux) |
| Cert trust | TOFU pin via `URLSession` delegate | TOFU pin via `HttpClientHandler` callback + `SslStream` callback (video) |

The video engine is a custom pipeline on **FFmpeg** (`FfmpegEngine` +
`VideoStreamClient`/`VideoStreamCoordinator`/`VideoSurface`): FFmpeg demuxes
RTSP and decodes H.264/H.265, and the frames are composited inside Avalonia —
no native child windows, so video is clickable, gesture-capable, and
overlayable. (An earlier iteration used libVLC; it was replaced because a
native `VideoView` child window can't participate in Avalonia hit-testing or
overlays.) TLS is bridged by `RtspTlsTunnel`: a 127.0.0.1 listener that pipes
bytes over TLS to the controller with the same TOFU pinning as the API client,
so FFmpeg plays plain `rtsp://127.0.0.1:…` while the wire stays encrypted and
pinned.

## Project layout

```
dotnet/
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
      Services/    PinnedWindowManager, SnapshotService
      Video/       FfmpegEngine, VideoStreamClient, VideoStreamCoordinator,
                   VideoSurface (the custom FFmpeg video pipeline)
      ViewModels/  Main, CameraTile, Settings, Onboarding, Layout
      Views/       MainWindow (grid/focus), SettingsWindow, OnboardingWindow,
                   PinnedCameraWindow
      Localization/                # 7 languages from the macOS String Catalog
  tests/QuickProtect.Core.Tests/   # unit tests for the Core layer
  installer/QuickProtect.iss       # Inno Setup script (free GitHub build)
  installer/msix/                  # MSIX manifest + tile assets (Store build)
  scripts/get-ffmpeg.ps1           # fetch FFmpeg natives (Windows RIDs by default)
  scripts/get-ffmpeg.sh            # same, for Linux (host-arch RID by default)
  scripts/package-windows.ps1      # publish + build the Windows installer
  scripts/package-msix.ps1         # publish + build the Store (MSIX) package
  scripts/generate-msix-assets.swift  # regenerate the MSIX tile PNGs (macOS)
```

## Build & run

Prerequisites: **.NET 8 SDK**, plus the **FFmpeg 7.1 shared libraries** for
video. Fetch them once per checkout into `native/ffmpeg/<rid>/` (gitignored);
the build bundles them next to the app automatically:

```bash
cd dotnet
./scripts/get-ffmpeg.sh                            # Linux (host arch; or pass linux-x64 linux-arm64)
powershell -File scripts/get-ffmpeg.ps1            # Windows (win-x64 + win-arm64)
```

If the bundle is absent, the engine falls back to system-installed FFmpeg
libraries — that only works when the system major version matches the
`FFmpeg.AutoGen` binding (7.x, i.e. `libavcodec.so.61`); otherwise the app
still runs, just with video disabled.

```bash
dotnet build QuickProtect.sln
dotnet test tests/QuickProtect.Core.Tests
dotnet run --project src/QuickProtect.App          # host-arch build
dotnet publish src/QuickProtect.App -c Release -r win-x64 --self-contained
```

Or use the repo scripts, which build, replace any running instance, and launch:
`scripts\windows\run.ps1` (Windows) / `scripts/linux/run.sh` (Linux), from the
repo root.

The app launches as a tray agent (no main window). Left-click the tray icon to
open the camera grid; right-click for the menu. Open **Settings** to enter the
controller IP and Integration API key. `--open-panel` opens the grid immediately
(useful for testing).

Diagnostics: fatal errors land in `%APPDATA%\QuickProtect\crash.log`
(`~/.config/QuickProtect/` on Linux), FFmpeg warnings/errors in `video.log`
next to it.

## Packaging (Windows)

Two artifacts, matching the two distribution channels (see
[`PARITY.md`](../docs/PARITY.md#distribution-future)).

**Free build** — unsigned installer for GitHub releases. The SmartScreen
warning it triggers is the intended friction; it is not signed on purpose.

```powershell
winget install JRSoftware.InnoSetup   # once
powershell -File scripts/package-windows.ps1
# → dist/QuickProtect-Setup-<version>-win-x64.exe
```

**Paid build** — MSIX for the Microsoft Store. Upload the package *unsigned*;
Partner Center re-signs it with a Microsoft certificate, so no code-signing
certificate is needed.

```powershell
powershell -File scripts/package-msix.ps1
# → dist/QuickProtect-<version>-win-x64.msix
```

This needs `makeappx.exe`. If no Windows SDK is installed the script fetches
just the tools from NuGet (~30 MB, no admin, cached in `native/`). To use a full
SDK instead, install it once — note the ID is versioned, plain
`Microsoft.WindowsSDK` no longer resolves:

```powershell
winget install Microsoft.WindowsSDK.10.0.26100
```

`-IdentityName` and `-Publisher` default to the reserved app's real values from
**Partner Center → QuickProtect → Product identity**, so the plain command above
is uploadable as-is. They must match exactly or the upload is rejected twice
over: once on the publisher string, and once on the package family name, whose
`_g3ygdvw278mtr` suffix is a hash of that publisher.

To sideload for local testing instead, run with `-SelfSign` and import the
generated certificate into *Trusted People*. This writes a **separate**
`-sideload.msix` file — it carries the test certificate's identity and Partner
Center will reject it, so never upload that one:

```powershell
powershell -File scripts/package-msix.ps1 -SelfSign
# → dist/QuickProtect-<version>-win-x64-sideload.msix
```

The manifest declares only the `Windows.Desktop` device family, so in Partner
Center leave **Windows 10/11 Desktop** checked and uncheck everything else —
a checked family with no matching package blocks submission.

Partner Center always flags `runFullTrust` as a restricted capability needing
approval. That warning is expected, not a defect: it is required for any Win32
app in an MSIX container and is reviewed during certification. Justify it in
*Notes for certification* — full-trust desktop app bundling a native FFmpeg
decoder, talking to the user's own UniFi Protect console on the LAN.

The tile PNGs under `installer/msix/Assets/` are committed and drawn from the
same Aurora design as the macOS icon. Regenerate them only if the icon changes
(requires macOS):

```bash
swift scripts/generate-msix-assets.swift installer/msix/Assets
```

Two behaviours differ inside the MSIX container, both handled in code:
settings still land in `%APPDATA%\QuickProtect` (Windows redirects it into the
package's private store), and launch-at-login switches from the `Run` registry
key — which a packaged app cannot use — to the manifest's `windows.startupTask`,
managed by Windows under Settings → Apps → Startup.

## Feature parity status

The port is at feature parity with the macOS app for day-to-day use: tray shell,
live camera grid, focus view with PTZ (d-pad + keyboard, quick-tap min-burst),
pinned always-on-top windows, snapshots (folder or clipboard), secondary-lens
PiP, layout profiles, onboarding, global hotkey, notify-only update checks,
TOFU certificate pinning end-to-end (API + video), theming with accent colors,
audio playback (WASAPI/ALSA), and 7-language localization.

See [`PARITY.md`](../docs/PARITY.md) for the detailed feature-by-feature status
and the remaining polish items.
